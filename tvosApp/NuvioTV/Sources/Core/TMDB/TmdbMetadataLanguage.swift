import Foundation

/// Auto is local to this profile/device. Existing cross-platform language tags
/// remain ordinary manual tags; no new sentinel is sent to other clients.
enum TmdbMetadataLanguage {
    static func followsApp(in store: UserDefaults) -> Bool {
        if store.object(forKey: SettingsKey.tmdbFollowAppLanguage) != nil {
            return store.bool(forKey: SettingsKey.tmdbFollowAppLanguage)
        }
        // Preserve every saved legacy choice, including a saved English default.
        return store.string(forKey: SettingsKey.tmdbLanguage)?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }

    static func resolvedLanguage(
        in store: UserDefaults,
        systemLanguage: String = Locale.preferredLanguages.first ?? "en"
    ) -> String {
        guard followsApp(in: store) else {
            return normalized(store.string(forKey: SettingsKey.tmdbLanguage) ?? "en")
        }
        let raw = store.string(forKey: SettingsKey.language)
            ?? UserDefaults.standard.string(forKey: SettingsKey.language)
        let appLanguage = AppLanguage.fromStored(raw)
        guard appLanguage == .system else { return normalized(appLanguage.tag) }
        // Only use the device language when Nuvio itself is set to System.
        let exact = AppLanguage.fromStored(systemLanguage)
        if exact != .system { return normalized(exact.tag) }
        let base = systemLanguage.replacingOccurrences(of: "_", with: "-")
            .split(separator: "-").first.map(String.init) ?? "en"
        let supported = AppLanguage.fromStored(base)
        return normalized(supported == .system ? "en" : supported.tag)
    }

    static func selectAutomatic(in store: UserDefaults) {
        store.set(true, forKey: SettingsKey.tmdbFollowAppLanguage)
    }

    static func selectManual(_ language: String, in store: UserDefaults) {
        store.set(language, forKey: SettingsKey.tmdbLanguage)
        store.set(false, forKey: SettingsKey.tmdbFollowAppLanguage)
    }

    static func normalized(_ value: String) -> String {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        guard !raw.isEmpty else { return "en" }
        if raw.caseInsensitiveCompare("es-419") == .orderedSame { return "es-MX" }
        let parts = raw.split(separator: "-", omittingEmptySubsequences: true)
        guard let first = parts.first else { return "en" }
        let language = first.lowercased()
        let code = language == "in" ? "id" : (language == "iw" ? "he" : language)
        return parts.count > 1 ? "\(code)-\(parts[1].uppercased())" : code
    }
}
