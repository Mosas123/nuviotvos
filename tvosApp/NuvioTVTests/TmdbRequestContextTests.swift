import Foundation
import XCTest
@testable import NuvioTV

@MainActor
final class TmdbRequestContextTests: XCTestCase {
    func testSettingsRemainCapturedAcrossSuspensionAndDirectResolution() async {
        let suiteName = "tmdb-context-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(" dummy-key-A ", forKey: SettingsKey.tmdbApiKey)
        defaults.set(true, forKey: SettingsKey.tmdbEnabled)
        defaults.set("es_419", forKey: SettingsKey.tmdbLanguage)
        defaults.set(true, forKey: SettingsKey.tmdbUseArtwork)

        await TmdbDetailsService.withRequestContext(defaults: defaults) {
            defaults.set("dummy-key-B", forKey: SettingsKey.tmdbApiKey)
            defaults.set(false, forKey: SettingsKey.tmdbEnabled)
            defaults.set("fr-FR", forKey: SettingsKey.tmdbLanguage)
            defaults.set(false, forKey: SettingsKey.tmdbUseArtwork)
            await Task.yield()

            XCTAssertEqual(TmdbDetailsService.currentApiKey, "dummy-key-A")
            XCTAssertEqual(TmdbDetailsService.preferredLanguage, "es-MX")
            XCTAssertTrue(TmdbDetailsService.useArtwork)
            let resolved = await TmdbDetailsService.resolveTmdbId(
                for: NuvioMeta(id: "tmdb:123", name: "Snapshot", type: "movie")
            )
            XCTAssertEqual(resolved?.id, 123, "Captured enabled/key still allow the direct path")
        }
    }

    func testNestedOperationsReuseSnapshotAndLaterOperationsCaptureFreshValues() async {
        let suiteName = "tmdb-context-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("en-US", forKey: SettingsKey.tmdbLanguage)

        await TmdbDetailsService.withRequestContext(defaults: defaults) {
            defaults.set("de-DE", forKey: SettingsKey.tmdbLanguage)
            await TmdbDetailsService.withRequestContext(defaults: defaults) {
                XCTAssertEqual(TmdbDetailsService.preferredLanguage, "en-US")
            }
        }
        await TmdbDetailsService.withRequestContext(defaults: defaults) {
            XCTAssertEqual(TmdbDetailsService.preferredLanguage, "de-DE")
        }
    }

    func testStructuredBatchChildrenInheritSnapshotAndModuleDefaults() async {
        let suiteName = "tmdb-context-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let inherited = await TmdbDetailsService.withRequestContext(defaults: defaults) {
            defaults.set("fr-FR", forKey: SettingsKey.tmdbLanguage)
            defaults.set(true, forKey: SettingsKey.tmdbApplyToHome)
            defaults.set(false, forKey: SettingsKey.tmdbUseBasicInfo)
            return await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
                for _ in 0..<8 {
                    group.addTask {
                        await Task.yield()
                        return TmdbDetailsService.preferredLanguage == "en"
                            && TmdbDetailsService.useBasicInfo
                            && !TmdbDetailsService.useHomeEnrichment
                    }
                }
                var allInherited = true
                for await result in group { allInherited = allInherited && result }
                return allInherited
            }
        }
        XCTAssertTrue(inherited)
    }
}
