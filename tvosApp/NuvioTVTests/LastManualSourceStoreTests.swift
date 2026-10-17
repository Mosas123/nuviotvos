import Foundation
import XCTest
@testable import NuvioTV

@MainActor
final class LastManualSourceStoreTests: XCTestCase {
    private func withStore(_ body: (UserDefaults) -> Void) {
        let name = "LastManualSourceStoreTests.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        store.set(true, forKey: SettingsKey.rememberLastSourceFocus)
        body(store)
    }

    func testPreferenceDefaultsOffAndDisablingStopsWritesAndRestoration() {
        withStore { store in
            let preference = SettingsKey.rememberLastSourceFocus
            store.removeObject(forKey: preference)
            func remember(_ source: String) {
                LastManualSourceStore.remember(sourceID: source, profileID: "a", metaID: "movie",
                    type: "movie", season: nil, episode: nil, store: store, preferences: store)
            }
            func match() -> String? {
                LastManualSourceStore.matchingID(in: ["hash:first", "hash:second"], profileID: "a",
                    metaID: "movie", type: "movie", season: nil, episode: nil, store: store, preferences: store)
            }
            // A missing preference must neither write history nor restore focus.
            remember("hash:first")
            XCTAssertNil(match())
            XCTAssertNil(store.data(forKey: "nuvio.tv.manualSourceFocus.v1"))
            store.set(true, forKey: preference)
            remember("hash:first")
            XCTAssertEqual(match(), "hash:first")
            store.set(false, forKey: preference)
            remember("hash:second")
            XCTAssertNil(match())
            XCTAssertFalse(LastManualSourceStore.hasRememberedSource(profileID: "a", metaID: "movie",
                type: "movie", season: nil, episode: nil, store: store, preferences: store))
            // Existing history is retained, but disabled playback must not overwrite it.
            store.set(true, forKey: preference)
            XCTAssertEqual(match(), "hash:first")
        }
    }

    func testExactMatchSurvivesReorderingWithoutUsingRowIndex() {
        withStore { store in
            LastManualSourceStore.remember(sourceID: "https://example.test/b", profileID: "a",
                metaID: "movie", type: "movie", season: nil, episode: nil, store: store, preferences: store)
            XCTAssertEqual(LastManualSourceStore.matchingID(
                in: ["https://example.test/c", "https://example.test/a", "https://example.test/b"],
                profileID: "a", metaID: "movie", type: "movie", season: nil, episode: nil,
                store: store, preferences: store), "https://example.test/b")
            XCTAssertNil(LastManualSourceStore.matchingID(in: ["https://example.test/a"],
                profileID: "a", metaID: "movie", type: "movie", season: nil, episode: nil,
                store: store, preferences: store))
        }
    }

    func testProfileTitleAndEpisodeIsolation() {
        withStore { store in
            LastManualSourceStore.remember(sourceID: "hash:1", profileID: "a", metaID: "series",
                type: "series", season: 1, episode: 2, store: store, preferences: store)
            for (profile, title, season, episode) in [
                ("b", "series", 1, 2), ("a", "other", 1, 2),
                ("a", "series", 2, 2), ("a", "series", 1, 3)
            ] {
                XCTAssertNil(LastManualSourceStore.matchingID(in: ["hash:1"], profileID: profile,
                    metaID: title, type: "series", season: season, episode: episode, store: store, preferences: store))
            }
            XCTAssertEqual(LastManualSourceStore.matchingID(in: ["hash:1"], profileID: "a",
                metaID: "series", type: "series", season: 1, episode: 2, store: store, preferences: store), "hash:1")
        }
    }

    func testAmbiguousAndUnplayableFallbackIdentitiesAreNotRestored() {
        withStore { store in
            LastManualSourceStore.remember(sourceID: "hash:1", profileID: "a", metaID: "movie",
                type: "movie", season: nil, episode: nil, store: store, preferences: store)
            XCTAssertNil(LastManualSourceStore.matchingID(in: ["hash:1", "hash:1"], profileID: "a",
                metaID: "movie", type: "movie", season: nil, episode: nil, store: store, preferences: store))
            LastManualSourceStore.remember(sourceID: "stream:display text", profileID: "a",
                metaID: "other", type: "movie", season: nil, episode: nil, store: store, preferences: store)
            XCTAssertFalse(LastManualSourceStore.hasRememberedSource(profileID: "a", metaID: "other",
                type: "movie", season: nil, episode: nil, store: store, preferences: store))
            LastManualSourceStore.remember(sourceID: "hash:1", profileID: "a", metaID: "series",
                type: "series", season: nil, episode: nil, store: store, preferences: store)
            XCTAssertFalse(LastManualSourceStore.hasRememberedSource(profileID: "a", metaID: "series",
                type: "series", season: nil, episode: nil, store: store, preferences: store))
        }
    }

    func testHistoryIsBoundedAndDoesNotPersistRawSourceCredentials() {
        withStore { store in
            for index in 0..<405 {
                LastManualSourceStore.remember(sourceID: "https://example.test/video?token=private-secret",
                    profileID: "private-profile", metaID: "movie-\(index)", type: "movie",
                    season: nil, episode: nil, store: store, preferences: store)
            }
            let data = store.dictionaryRepresentation().values.compactMap { $0 as? Data }.first!
            let entries = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            XCTAssertEqual(entries.count, 400)
            let raw = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(raw.contains("private-secret"))
            XCTAssertFalse(raw.contains("private-profile"))
            XCTAssertFalse(raw.contains("example.test"))
        }
    }
}
