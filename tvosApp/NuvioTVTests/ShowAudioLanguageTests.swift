//
//  ShowAudioLanguageTests.swift
//  NuvioTVTests
//
//  Unit tests for per-show audio language playback preference (Issue #191).
//

import XCTest
@testable import NuvioTV

final class ShowAudioLanguageTests: XCTestCase {
    private let suiteName = "ShowAudioLanguageTestsSuite"
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: suiteName)!
        testDefaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        testDefaults?.removePersistentDomain(forName: suiteName)
        testDefaults = nil
        super.tearDown()
    }

    func testShowAudioLanguagesKeyDefinedAndInAll() {
        XCTAssertEqual(SettingsKey.showAudioLanguages, "nuvio.tv.settings.playback.showAudioLanguages")
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.showAudioLanguages), "showAudioLanguages must be included in SettingsKey.all for iCloud and profile sync")
    }

    func testShowAudioLanguageStoreGetSetAndClear() {
        let showId1 = "tt0903747" // Breaking Bad
        let showId2 = "tt0944947" // Game of Thrones

        XCTAssertNil(ShowAudioLanguageStore.getLanguage(for: showId1, defaults: testDefaults))

        // Set language for show 1
        ShowAudioLanguageStore.setLanguage("Spanish", for: showId1, defaults: testDefaults)
        XCTAssertEqual(ShowAudioLanguageStore.getLanguage(for: showId1, defaults: testDefaults), "Spanish")
        XCTAssertNil(ShowAudioLanguageStore.getLanguage(for: showId2, defaults: testDefaults))

        // Set language for show 2
        ShowAudioLanguageStore.setLanguage("French", for: showId2, defaults: testDefaults)
        XCTAssertEqual(ShowAudioLanguageStore.getLanguage(for: showId1, defaults: testDefaults), "Spanish")
        XCTAssertEqual(ShowAudioLanguageStore.getLanguage(for: showId2, defaults: testDefaults), "French")

        // Clear show 1 using nil
        ShowAudioLanguageStore.setLanguage(nil, for: showId1, defaults: testDefaults)
        XCTAssertNil(ShowAudioLanguageStore.getLanguage(for: showId1, defaults: testDefaults))
        XCTAssertEqual(ShowAudioLanguageStore.getLanguage(for: showId2, defaults: testDefaults), "French")

        // Clear show 2 using "Default"
        ShowAudioLanguageStore.setLanguage("Default", for: showId2, defaults: testDefaults)
        XCTAssertNil(ShowAudioLanguageStore.getLanguage(for: showId2, defaults: testDefaults))
    }

    func testPreferredAudioLanguageResolutionWithShowOverride() {
        let showId = "ttAnime123"
        let animeMeta = NuvioMeta(
            id: showId,
            name: "Anime Series",
            type: "series",
            genres: ["Anime", "Action"],
            language: "ja"
        )

        // 1. Global is "Original", show has no override -> resolves to "Japanese" for anime
        testDefaults.set("Original", forKey: SettingsKey.audioLanguage)
        let resolvedInitial = SubtitleLanguagePreferences.preferredAudioLanguage(meta: animeMeta, defaults: testDefaults)
        XCTAssertEqual(resolvedInitial, "Japanese")

        // 2. Set per-show override to "English" -> overrides global "Original"
        ShowAudioLanguageStore.setLanguage("English", for: showId, defaults: testDefaults)
        let resolvedOverridden = SubtitleLanguagePreferences.preferredAudioLanguage(meta: animeMeta, defaults: testDefaults)
        XCTAssertEqual(resolvedOverridden, "English")

        // 3. Global is "French", per-show is still "English" -> returns "English"
        testDefaults.set("French", forKey: SettingsKey.audioLanguage)
        let resolvedStillEnglish = SubtitleLanguagePreferences.preferredAudioLanguage(meta: animeMeta, defaults: testDefaults)
        XCTAssertEqual(resolvedStillEnglish, "English")

        // 4. Per-show override set to "Original" while global is "French" -> returns original language ("Japanese")
        ShowAudioLanguageStore.setLanguage("Original", for: showId, defaults: testDefaults)
        let resolvedShowOriginal = SubtitleLanguagePreferences.preferredAudioLanguage(meta: animeMeta, defaults: testDefaults)
        XCTAssertEqual(resolvedShowOriginal, "Japanese")

        // 5. Clear per-show override -> reverts to global ("French")
        ShowAudioLanguageStore.setLanguage(nil, for: showId, defaults: testDefaults)
        let resolvedReverted = SubtitleLanguagePreferences.preferredAudioLanguage(meta: animeMeta, defaults: testDefaults)
        XCTAssertEqual(resolvedReverted, "French")
    }

    func testPlayerViewModelDetectedLanguage() {
        // Track with language code "spa"
        let spanishTrack = AudioTrack(
            id: "1",
            name: "Track 1",
            language: "spa",
            isSelected: true,
            languageName: "",
            detail: "AC-3"
        )
        XCTAssertEqual(PlayerViewModel.detectedLanguage(for: spanishTrack), "Spanish")

        // Track with language code "ja"
        let japaneseTrack = AudioTrack(
            id: "2",
            name: "Surround",
            language: "ja",
            isSelected: true,
            languageName: "",
            detail: ""
        )
        XCTAssertEqual(PlayerViewModel.detectedLanguage(for: japaneseTrack), "Japanese")

        // Track with languageName "French"
        let frenchTrack = AudioTrack(
            id: "3",
            name: "Dialogue",
            language: "und",
            isSelected: true,
            languageName: "French",
            detail: ""
        )
        XCTAssertEqual(PlayerViewModel.detectedLanguage(for: frenchTrack), "French")

        // Track with name containing language "German"
        let germanTrack = AudioTrack(
            id: "4",
            name: "German (5.1 Surround)",
            language: "",
            isSelected: true,
            languageName: "",
            detail: ""
        )
        XCTAssertEqual(PlayerViewModel.detectedLanguage(for: germanTrack), "German")

        // Track with unknown / undetermined name
        let unknownTrack = AudioTrack(
            id: "5",
            name: "Track 5",
            language: "und",
            isSelected: true,
            languageName: "",
            detail: ""
        )
        XCTAssertNil(PlayerViewModel.detectedLanguage(for: unknownTrack))
    }

    func testShowAudioLanguageNotificationPosted() {
        let expectation = expectation(description: "Notification posted")
        expectation.assertForOverFulfill = false
        let showId = "ttNotificationTest"
        var hasFulfilled = false

        let observer = NotificationCenter.default.addObserver(
            forName: .showAudioLanguageDidChange,
            object: nil,
            queue: .main
        ) { notification in
            guard let id = notification.userInfo?["showId"] as? String, id == showId else {
                return
            }
            guard !hasFulfilled else { return }
            hasFulfilled = true
            XCTAssertEqual(notification.userInfo?["language"] as? String, "Italian")
            expectation.fulfill()
        }

        ShowAudioLanguageStore.setLanguage("Italian", for: showId, defaults: testDefaults)

        wait(for: [expectation], timeout: 2.0)
        NotificationCenter.default.removeObserver(observer)
    }
}
