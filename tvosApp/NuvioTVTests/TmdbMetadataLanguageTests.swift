import Foundation
import XCTest
@testable import NuvioTV

@MainActor
final class TmdbMetadataLanguageTests: XCTestCase {
    private func withDefaults(_ operation: (UserDefaults) -> Void) {
        let suite = "tmdb-language-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }
        operation(store)
    }

    func testFreshSettingsFollowAppInsteadOfDeviceLanguage() {
        withDefaults { store in
            store.set("en", forKey: SettingsKey.language)
            XCTAssertTrue(TmdbMetadataLanguage.followsApp(in: store))
            XCTAssertEqual(TmdbMetadataLanguage.resolvedLanguage(in: store, systemLanguage: "es"), "en")
            store.set("es", forKey: SettingsKey.language)
            XCTAssertEqual(TmdbMetadataLanguage.resolvedLanguage(in: store, systemLanguage: "en"), "es")
        }
    }

    func testLegacySavedEnglishRemainsManual() {
        withDefaults { store in
            store.set("en", forKey: SettingsKey.tmdbLanguage)
            store.set("es", forKey: SettingsKey.language)
            XCTAssertFalse(TmdbMetadataLanguage.followsApp(in: store))
            XCTAssertEqual(TmdbMetadataLanguage.resolvedLanguage(in: store), "en")
            XCTAssertNil(store.object(forKey: SettingsKey.tmdbFollowAppLanguage))
        }
    }

    func testManualOverrideStaysSelectedUntilAutomaticIsChosenAgain() {
        withDefaults { store in
            store.set("es", forKey: SettingsKey.language)
            TmdbMetadataLanguage.selectManual("fr-FR", in: store)
            store.set("de", forKey: SettingsKey.language)
            XCTAssertEqual(TmdbMetadataLanguage.resolvedLanguage(in: store), "fr-FR")
            TmdbMetadataLanguage.selectAutomatic(in: store)
            XCTAssertEqual(TmdbMetadataLanguage.resolvedLanguage(in: store), "de")
            store.set("es", forKey: SettingsKey.language)
            XCTAssertEqual(TmdbMetadataLanguage.resolvedLanguage(in: store), "es")
            XCTAssertEqual(store.string(forKey: SettingsKey.tmdbLanguage), "fr-FR")
        }
    }

    func testExplicitSystemUsesSupportedDeviceLocaleAndFallback() {
        withDefaults { store in
            store.set("", forKey: SettingsKey.language)
            XCTAssertEqual(TmdbMetadataLanguage.resolvedLanguage(in: store, systemLanguage: "fr-CA"), "fr")
            XCTAssertEqual(TmdbMetadataLanguage.resolvedLanguage(in: store, systemLanguage: "zh-TW"), "zh-TW")
            XCTAssertEqual(TmdbMetadataLanguage.resolvedLanguage(in: store, systemLanguage: "zz-ZZ"), "en")
        }
    }

    func testLanguageAliasesAndLatinAmericanSpanish() {
        withDefaults { store in
            store.set("es-419", forKey: SettingsKey.language)
            XCTAssertEqual(TmdbMetadataLanguage.resolvedLanguage(in: store), "es-MX")
            store.set("in", forKey: SettingsKey.language)
            XCTAssertEqual(TmdbMetadataLanguage.resolvedLanguage(in: store), "id")
            TmdbMetadataLanguage.selectManual(" pt_br ", in: store)
            XCTAssertEqual(TmdbMetadataLanguage.resolvedLanguage(in: store), "pt-BR")
        }
    }

    func testIndependentStoresDoNotShareTheMode() {
        withDefaults { first in
            withDefaults { second in
                first.set("es", forKey: SettingsKey.language)
                second.set("es", forKey: SettingsKey.language)
                TmdbMetadataLanguage.selectManual("en", in: first)
                XCTAssertEqual(TmdbMetadataLanguage.resolvedLanguage(in: first), "en")
                XCTAssertEqual(TmdbMetadataLanguage.resolvedLanguage(in: second), "es")
                XCTAssertTrue(SettingsKey.deviceLocal.contains(SettingsKey.tmdbFollowAppLanguage))
                XCTAssertTrue(SettingsKey.all.contains(SettingsKey.tmdbFollowAppLanguage))
            }
        }
    }

    func testAutomaticLanguageIsCapturedForAnInFlightOperation() async {
        let suite = "tmdb-auto-context-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }
        store.set("en", forKey: SettingsKey.language)
        await TmdbDetailsService.withRequestContext(defaults: store) {
            store.set("es", forKey: SettingsKey.language)
            await Task.yield()
            XCTAssertEqual(TmdbDetailsService.preferredLanguage, "en")
        }
        await TmdbDetailsService.withRequestContext(defaults: store) {
            XCTAssertEqual(TmdbDetailsService.preferredLanguage, "es")
        }
    }

    func testLanguageChangeInvalidatesFullMetadataAndRejectsOldResponse() {
        withLiveSettings { store in
            let repository = CinemetaCatalogRepository()
            let oldContext = CinemetaCatalogRepository.metadataCacheContext
            let oldSignature = repository.homeCatalogInputSignature
            let english = NuvioMeta(id: "tt1234567", name: "English", type: "movie")
            repository.cacheMetadata(english, context: oldContext)
            XCTAssertTrue(repository.isCachedFullMetadata(id: english.id))

            store.set("es", forKey: SettingsKey.language)
            XCTAssertNil(repository.cachedMetadata(for: english.id))
            XCTAssertFalse(repository.isCachedFullMetadata(id: english.id))
            XCTAssertNotEqual(repository.homeCatalogInputSignature, oldSignature)
            repository.cacheMetadata(english, context: oldContext)
            XCTAssertNil(repository.cachedMetadata(for: english.id))

            let spanish = NuvioMeta(id: english.id, name: "Español", type: "movie")
            repository.cacheMetadata(spanish)
            repository.cacheMetadata(english, context: oldContext)
            XCTAssertEqual(repository.cachedMetadata(for: english.id)?.name, "Español")
        }
    }

    func testChangingAppLanguageWithManualOverrideKeepsMetadataCache() {
        withLiveSettings { store in
            TmdbMetadataLanguage.selectManual("en", in: store)
            let repository = CinemetaCatalogRepository()
            let meta = NuvioMeta(id: "tt1234567", name: "English", type: "movie")
            repository.cacheMetadata(meta)
            let context = CinemetaCatalogRepository.metadataCacheContext
            store.set("es", forKey: SettingsKey.language)
            XCTAssertEqual(CinemetaCatalogRepository.metadataCacheContext, context)
            XCTAssertEqual(repository.cachedMetadata(for: meta.id)?.name, "English")
        }
    }

    func testOldRequestSnapshotCannotWriteIntoNewLanguageContext() async {
        let suite = "tmdb-old-language-\(UUID().uuidString)"
        let snapshotStore = UserDefaults(suiteName: suite)!
        defer { snapshotStore.removePersistentDomain(forName: suite) }
        snapshotStore.set("en", forKey: SettingsKey.language)
        await TmdbDetailsService.withRequestContext(defaults: snapshotStore) {
            withLiveSettings { store in
                store.set("es", forKey: SettingsKey.language)
                let repository = CinemetaCatalogRepository()
                repository.cacheMetadata(
                    NuvioMeta(id: "tt1234567", name: "Old English response", type: "movie"),
                    context: CinemetaCatalogRepository.metadataCacheContext
                )
                XCTAssertNil(repository.cachedMetadata(for: "tt1234567"))
            }
        }
    }

    private func withLiveSettings(_ operation: (UserDefaults) -> Void) {
        let store = ProfileSettings.current
        let keys = [SettingsKey.language, SettingsKey.tmdbLanguage, SettingsKey.tmdbFollowAppLanguage]
        let previous = keys.map { ($0, store.object(forKey: $0)) }
        defer {
            for (key, value) in previous {
                if let value { store.set(value, forKey: key) }
                else { store.removeObject(forKey: key) }
            }
            CinemetaCatalogRepository.clearMetadataCache()
        }
        CinemetaCatalogRepository.clearMetadataCache()
        store.set("en", forKey: SettingsKey.language)
        TmdbMetadataLanguage.selectAutomatic(in: store)
        operation(store)
    }
}
