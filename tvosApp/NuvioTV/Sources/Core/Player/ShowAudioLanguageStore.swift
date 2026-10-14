//
//  ShowAudioLanguageStore.swift
//  NuvioTV
//
//  Created for Issue #191: Per-show audio language playback preference.
//

import Foundation

extension Notification.Name {
    static let showAudioLanguageDidChange = Notification.Name("nuvio.tv.showAudioLanguage.changed")
}

/// Persistent store for per-show / per-title audio language preferences.
/// Allows a user to override the global audio language setting for a specific show or movie.
enum ShowAudioLanguageStore {
    private static let lock = NSLock()

    /// Resolves the canonical key for a show/title from its metadata.
    static func canonicalKey(meta: NuvioMeta?) -> String? {
        guard let id = meta?.id.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            return nil
        }
        return id
    }

    /// Returns the saved audio language override for the given show ID, if any.
    /// Returns `nil` when no override is set (the show will follow the global audio language setting).
    static func getLanguage(
        for showId: String,
        defaults: UserDefaults = ProfileSettings.current
    ) -> String? {
        let cleanId = showId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty else { return nil }

        lock.lock()
        defer { lock.unlock() }

        let map = loadMap(from: defaults)
        return map[cleanId]?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sets or clears an audio language override for the given show ID.
    /// Passing `nil`, an empty string, or `"Default"` removes the override, restoring global behavior.
    static func setLanguage(
        _ language: String?,
        for showId: String,
        defaults: UserDefaults = ProfileSettings.current
    ) {
        let cleanId = showId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty else { return }

        lock.lock()
        var map = loadMap(from: defaults)
        let oldValue = map[cleanId]

        if let lang = language?.trimmingCharacters(in: .whitespacesAndNewlines),
           !lang.isEmpty,
           lang.caseInsensitiveCompare("Default") != .orderedSame {
            map[cleanId] = lang
        } else {
            map.removeValue(forKey: cleanId)
        }
        saveMap(map, to: defaults)
        let newValue = map[cleanId]
        lock.unlock()

        if oldValue != newValue {
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .showAudioLanguageDidChange,
                    object: nil,
                    userInfo: ["showId": cleanId, "language": newValue as Any]
                )
            }
        }
    }

    private static func loadMap(from defaults: UserDefaults) -> [String: String] {
        guard let json = defaults.string(forKey: SettingsKey.showAudioLanguages),
              let data = json.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return map
    }

    private static func saveMap(_ map: [String: String], to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(map),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        defaults.set(json, forKey: SettingsKey.showAudioLanguages)
    }
}
