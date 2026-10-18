import Foundation
import CryptoKit

/// Profile-local removal receipts stop late Home/sync results from restoring an
/// uninstalled source. They contain identity only, never catalog preferences.
enum AddonCatalogRemovalStore {
    private static let key = "nuvio.tv.settings.layout.removedAddonCatalogSources"
    private static let generationKey = "nuvio.tv.settings.layout.addonCatalogRemovalGeneration"
    private static let identityKey = "nuvio.tv.settings.layout.addonCatalogSourceIdentities"
    private static let pendingKey = "nuvio.tv.settings.layout.pendingAddonCatalogRemovals"
    private static let lock = NSRecursiveLock()

    static func generation(in settings: UserDefaults) -> Int { settings.integer(forKey: generationKey) }

    private static func pending(in settings: UserDefaults) -> Set<String> {
        Set(settings.stringArray(forKey: pendingKey) ?? [])
    }

    static func hasPendingRemoval(in settings: UserDefaults) -> Bool { !pending(in: settings).isEmpty }

    /// Until a pull observes the removal on the server, an older addon list
    /// cannot undo local intent. A later remote reinstall is accepted after
    /// that acknowledgement; local reinstall clears the pending receipt too.
    static func filterRemote(_ preferences: [StreamAddonPreference], in settings: UserDefaults) -> [StreamAddonPreference] {
        lock.lock()
        defer { lock.unlock() }
        let received = Set(preferences.compactMap { normalized($0.url) })
        let outstanding = pending(in: settings).intersection(received)
        if outstanding.isEmpty { settings.removeObject(forKey: pendingKey) }
        else { settings.set(Array(outstanding), forKey: pendingKey) }
        return preferences.filter { preference in
            guard let url = normalized(preference.url) else { return false }
            return !outstanding.contains(url)
        }
    }

    private static func identities(in settings: UserDefaults) -> [String: String] {
        guard let data = settings.data(forKey: identityKey),
              let value = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return value
    }

    private static func saveIdentities(_ value: [String: String], in settings: UserDefaults) {
        if value.isEmpty { settings.removeObject(forKey: identityKey) }
        else if let data = try? JSONEncoder().encode(value) { settings.set(data, forKey: identityKey) }
    }

    struct Context {
        let manifestURLs: Set<String>
        let addonIDs: Set<String>

        func removes(_ row: TVHomeCatalogOrder.SnapshotRow) -> Bool {
            guard !manifestURLs.isEmpty || !addonIDs.isEmpty else { return false }
            if row.id.hasPrefix(TVHomeSection.collectionIdPrefix)
                || row.settingsKey?.hasPrefix(TVHomeSection.collectionIdPrefix) == true { return false }
            if addonIDs.contains(CinemetaCatalogRepository.cinemetaAddonId),
               ["movie_top", "series_top", "movie_rating", "series_rating"].contains(row.id) { return true }
            if let raw = row.manifestURL, let url = AddonCatalogRemovalStore.normalized(raw) {
                return manifestURLs.contains(url)
            }
            return row.addonId.map(addonIDs.contains) ?? false
        }
    }

    private static func normalized(_ raw: String) -> String? {
        guard let url = CinemetaCatalogRepository.normalizedManifestURL(from: raw)?.absoluteString else { return nil }
        // Manifest URLs can contain credentials; removal receipts keep a digest.
        return SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func receipts(in settings: UserDefaults) -> [String: Set<String>] {
        guard let data = settings.data(forKey: key),
              let value = try? JSONDecoder().decode([String: Set<String>].self, from: data) else { return [:] }
        return value
    }

    private static func save(_ value: [String: Set<String>], in settings: UserDefaults) {
        if value.isEmpty { settings.removeObject(forKey: key) }
        else if let data = try? JSONEncoder().encode(value) { settings.set(data, forKey: key) }
    }

    static func context(in settings: UserDefaults) -> Context {
        lock.lock()
        defer { lock.unlock() }
        let value = receipts(in: settings)
        return Context(manifestURLs: Set(value.keys), addonIDs: value.values.reduce(into: Set<String>()) { $0.formUnion($1) })
    }

    static func removeBuiltInCinemeta(in settings: UserDefaults) {
        let url = "https://v3-cinemeta.strem.io/manifest.json"
        update(previous: [StreamAddonPreference(url: url, enabled: true)],
               current: CinemetaCatalogRepository.configuredStreamAddonPreferences(in: settings),
               knownManifestIDs: [url: CinemetaCatalogRepository.cinemetaAddonId], in: settings)
    }

    /// Called only after the installed list is persisted. Disabled preferences
    /// remain installed, so disabling or reordering never starts cleanup.
    static func update(
        previous: [StreamAddonPreference], current: [StreamAddonPreference],
        knownManifestIDs: [String: String] = [:], in settings: UserDefaults,
        isLocalEdit: Bool = true
    ) {
        lock.lock()
        defer { lock.unlock() }
        let installed = Set(current.compactMap { normalized($0.url) })
        let previousURLs = Set(previous.compactMap { normalized($0.url) })
        let removed = previousURLs.subtracting(installed)
        var outstanding = pending(in: settings).subtracting(installed)
        if isLocalEdit { outstanding.formUnion(removed) }
        if outstanding.isEmpty { settings.removeObject(forKey: pendingKey) }
        else { settings.set(Array(outstanding), forKey: pendingKey) }
        if installed != previousURLs {
            settings.set(generation(in: settings) &+ 1, forKey: generationKey)
        }
        var value = receipts(in: settings).filter { !installed.contains($0.key) }
        guard !removed.isEmpty || value != receipts(in: settings) else { return }
        let rows = TVHomeCatalogOrder.snapshotRows(in: settings)
        var identities = identities(in: settings)
        for row in rows {
            if let raw = row.manifestURL, let url = normalized(raw), let id = row.addonId {
                identities[url] = id
            }
        }
        for (raw, id) in knownManifestIDs {
            if let url = normalized(raw) { identities[url] = id }
        }
        if let cinemeta = normalized("https://v3-cinemeta.strem.io/manifest.json"), removed.contains(cinemeta) {
            identities[cinemeta] = CinemetaCatalogRepository.cinemetaAddonId
        }
        let retainedIDs = Set(identities.filter { installed.contains($0.key) }.map(\.value))
        for url in removed {
            var ids = value[url] ?? Set<String>()
            if let id = identities[url], !retainedIDs.contains(id) { ids.insert(id) }
            value[url] = ids
        }
        // Another installed configuration can provide the same add-on ID.
        for url in Array(value.keys) { value[url]?.subtract(retainedIDs) }
        saveIdentities(identities.filter { installed.contains($0.key) }, in: settings)
        save(value, in: settings)
        guard !removed.isEmpty else { return }
        purge(rows: rows, removed: context(in: settings), retainedIDs: retainedIDs, in: settings)
    }

    /// Generic profile settings can also contain hero/catalog selections. Apply
    /// the same removal intent after importing them, not just the catalog RPC.
    static func reconcile(in settings: UserDefaults, profileID: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let profileID { settings.set(profileID, forKey: "nuvio.tv.profile.settings.profileID") }
        let removed = context(in: settings)
        guard !removed.manifestURLs.isEmpty else { return }
        let installed = Set(CinemetaCatalogRepository.configuredStreamAddonPreferences(in: settings).compactMap { normalized($0.url) })
        let retainedIDs = Set(identities(in: settings).filter { installed.contains($0.key) }.map(\.value))
        purge(rows: TVHomeCatalogOrder.snapshotRows(in: settings), removed: removed, retainedIDs: retainedIDs, in: settings)
    }

    /// A newly installed URL may intentionally reuse an old add-on ID. Resolve
    /// that from its actual manifest, never from its display name.
    static func didDiscover(addonID: String, manifestURL: String, in settings: UserDefaults) {
        lock.lock()
        defer { lock.unlock() }
        guard let url = normalized(manifestURL),
              CinemetaCatalogRepository.configuredStreamAddonPreferences(in: settings)
                .contains(where: { normalized($0.url) == url }) else { return }
        var identities = identities(in: settings)
        if identities[url] != addonID {
            identities[url] = addonID
            saveIdentities(identities, in: settings)
        }
        var value = receipts(in: settings)
        let old = value
        value.removeValue(forKey: url)
        for source in Array(value.keys) { value[source]?.remove(addonID) }
        if value != old { save(value, in: settings) }
    }

    private static func purge(
        rows: [TVHomeCatalogOrder.SnapshotRow], removed: Context,
        retainedIDs: Set<String>, in settings: UserDefaults
    ) {
        let removedRows = rows.filter(removed.removes)
        let sharedIDs = Set(rows.compactMap { row -> String? in
            guard !removed.removes(row), let id = row.addonId else { return nil }
            return id
        }).union(retainedIDs)
        let exclusiveIDs = removed.addonIDs.subtracting(sharedIDs)
        let knownIDs = exclusiveIDs.union(sharedIDs).sorted { $0.count > $1.count }
        let exactKeys = Set(removedRows.filter { row in
            row.addonId.map { !sharedIDs.contains($0) } ?? true
        }.flatMap { [$0.id, $0.settingsKey ?? "", TVHomeCatalogOrder.sectionOrderKey($0.id)] }).subtracting([""])
        func belongs(_ raw: String) -> Bool {
            let canonical = TVHomeCatalogOrder.sectionOrderKey(raw)
            guard !canonical.hasPrefix(TVHomeSection.collectionIdPrefix) else { return false }
            if exclusiveIDs.contains(CinemetaCatalogRepository.cinemetaAddonId),
               ["movie_top", "series_top", "movie_rating", "series_rating"].contains(raw) { return true }
            let owner = knownIDs.first(where: { canonical.hasPrefix($0 + "_") })
            if let owner, sharedIDs.contains(owner) { return false }
            if exactKeys.contains(raw) || exactKeys.contains(canonical) { return true }
            // Longest known identity prevents `a` from claiming `a_b`'s keys.
            guard let owner else { return false }
            return exclusiveIDs.contains(owner)
        }
        let arrayKeys = [SettingsKey.homeCatalogOrder, SettingsKey.homeCatalogSyncedOrder,
                         SettingsKey.homeCatalogDisabled, SettingsKey.homeCatalogExplicitEnabled,
                         SettingsKey.homeCatalogDeleted]
        var changes: [String: Data] = [:]
        for storageKey in arrayKeys {
            guard let data = HomeCatalogPayloadStore.data(forKey: storageKey, in: settings),
                  let keys = try? JSONDecoder().decode([String].self, from: data) else { continue }
            changes[storageKey] = try? JSONEncoder().encode(keys.filter { !belongs($0) })
        }
        if let data = HomeCatalogPayloadStore.data(forKey: SettingsKey.homeCatalogCustomTitles, in: settings),
           let titles = try? JSONDecoder().decode([String: String].self, from: data) {
            changes[SettingsKey.homeCatalogCustomTitles] = try? JSONEncoder().encode(titles.filter { !belongs($0.key) })
        }
        _ = HomeCatalogPayloadStore.writeBatch(changes, in: settings)
        if let data = settings.data(forKey: SettingsKey.heroCatalogs),
           let ids = try? JSONDecoder().decode([String].self, from: data),
           let clean = try? JSONEncoder().encode(ids.filter { !belongs($0) }) {
            settings.set(clean, forKey: SettingsKey.heroCatalogs)
        }
        if let data = settings.data(forKey: SettingsKey.homeCatalogDisabledAddonIDs),
           let ids = try? JSONDecoder().decode([String].self, from: data),
           let clean = try? JSONEncoder().encode(ids.filter { !exclusiveIDs.contains($0) }) {
            settings.set(clean, forKey: SettingsKey.homeCatalogDisabledAddonIDs)
        }
        let retainedNames = Set(rows.filter { !removed.removes($0) }.compactMap(\.addonName)
            .map(TVHomeCatalogOrder.normalizedAddonSourceName))
        let removedNames = Set(removedRows.compactMap(\.addonName)
            .map(TVHomeCatalogOrder.normalizedAddonSourceName)).subtracting(retainedNames)
        if let data = settings.data(forKey: SettingsKey.homeCatalogDisabledAddonNames),
           let names = try? JSONDecoder().decode([String].self, from: data),
           let clean = try? JSONEncoder().encode(names.filter { !removedNames.contains($0) }) {
            settings.set(clean, forKey: SettingsKey.homeCatalogDisabledAddonNames)
        }
        // Unknown names are ambiguous and are never used to infer ownership.
        // Collections and their source definitions are independently user-owned.
        TVHomeCatalogOrder.writeSnapshotRows(rows.filter { !removed.removes($0) }, in: settings)
        NotificationCenter.default.post(name: TVHomeCatalogOrder.changedNotification, object: nil)
    }
}
