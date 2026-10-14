//
//  ExternalRatingsTests.swift
//  NuvioTVTests
//
//  Unit tests for MDBList MAL & TVDB providers and Stremio add-on ratings.
//

import XCTest
@testable import NuvioTV

final class ExternalRatingsTests: XCTestCase {

    // MARK: - MDBList MAL & TVDB Provider Tests

    func testMdbListProviderPriorityOrderIncludesMyAnimeListAndTVDB() {
        let order = MdbListDetailsService.providerPriorityOrder
        XCTAssertTrue(order.contains(MdbListDetailsService.providerMyAnimeList))
        XCTAssertTrue(order.contains(MdbListDetailsService.providerTVDB))
        XCTAssertEqual(MdbListDetailsService.providerMyAnimeList, "myanimelist")
        XCTAssertEqual(MdbListDetailsService.providerTVDB, "tvdb")
    }

    func testMdbListApiProviderMappingMapsMyAnimeListToMal() {
        XCTAssertEqual(MdbListDetailsService.apiProvider(for: MdbListDetailsService.providerMyAnimeList), "mal")
        XCTAssertEqual(MdbListDetailsService.apiProvider(for: MdbListDetailsService.providerTVDB), "tvdb")
        XCTAssertEqual(MdbListDetailsService.apiProvider(for: MdbListDetailsService.providerIMDb), "imdb")
    }

    func testMdbListSyncMapperHandlesMyAnimeListAndTvdb() {
        let remoteToLocal = Dictionary(uniqueKeysWithValues: MdbListSyncMapper.remoteToLocalKeyMappings)
        XCTAssertEqual(remoteToLocal["mdblist_use_myanimelist"], SettingsKey.mdbListUseMyAnimeList)
        XCTAssertEqual(remoteToLocal["mdblist_use_mal"], SettingsKey.mdbListUseMyAnimeList)
        XCTAssertEqual(remoteToLocal["mdblist_use_tvdb"], SettingsKey.mdbListUseTvdb)

        let localToRemote = Dictionary(uniqueKeysWithValues: MdbListSyncMapper.localToRemoteKeyMappings)
        XCTAssertEqual(localToRemote[SettingsKey.mdbListUseMyAnimeList], "mdblist_use_myanimelist")
        XCTAssertEqual(localToRemote[SettingsKey.mdbListUseTvdb], "mdblist_use_tvdb")
    }

    // MARK: - Addon Rating Manifest & Resource Tests

    func testAddonRatingsManifestParsesRatingSources() throws {
        let json = """
        {
            "id": "org.csfd.ratings",
            "name": "ČSFD Ratings",
            "version": "1.0.0",
            "resources": [
                {
                    "name": "ratings",
                    "types": ["movie", "series"],
                    "idPrefixes": ["tt"]
                }
            ],
            "ratingSources": [
                {
                    "source": "csfd",
                    "name": "ČSFD",
                    "icon": "https://example.com/csfd.png",
                    "max": 100
                }
            ]
        }
        """.data(using: .utf8)!

        let manifest = try JSONDecoder().decode(AddonRatingsManifest.self, from: json)
        XCTAssertEqual(manifest.id, "org.csfd.ratings")
        XCTAssertEqual(manifest.displayName, "ČSFD Ratings")
        XCTAssertEqual(manifest.ratingSources?.count, 1)

        let source = try XCTUnwrap(manifest.ratingSources?.first)
        XCTAssertEqual(source.source, "csfd")
        XCTAssertEqual(source.name, "ČSFD")
        XCTAssertEqual(source.icon, "https://example.com/csfd.png")
        XCTAssertEqual(source.max, 100)

        XCTAssertTrue(manifest.supportsRatings(type: "movie", id: "tt0388629"))
        XCTAssertTrue(manifest.supportsRatings(type: "series", id: "tt0388629"))
        XCTAssertFalse(manifest.supportsRatings(type: "other", id: "tt0388629"))
        XCTAssertFalse(manifest.supportsRatings(type: "movie", id: "kitsu:123"))
    }

    func testAddonRatingsManifestStringResourceShorthand() throws {
        let json = """
        {
            "id": "org.simple.ratings",
            "resources": ["ratings"],
            "types": ["movie"],
            "ratingSources": [
                {
                    "source": "filmaffinity",
                    "name": "FilmAffinity",
                    "max": 10
                }
            ]
        }
        """.data(using: .utf8)!

        let manifest = try JSONDecoder().decode(AddonRatingsManifest.self, from: json)
        XCTAssertTrue(manifest.supportsRatings(type: "movie", id: "any:id"))
        XCTAssertFalse(manifest.supportsRatings(type: "series", id: "any:id"))
    }

    // MARK: - Addon Rating Response & Decoding Tests

    func testAddonRatingsResponseDecodesNumbersAndStrings() throws {
        let json = """
        {
            "ratings": [
                {
                    "source": "csfd",
                    "value": 84,
                    "url": "https://www.csfd.cz/film/12345"
                },
                {
                    "source": "douban",
                    "value": "9.1",
                    "url": "https://movie.douban.com/subject/12345"
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(AddonRatingsResponse.self, from: json)
        let ratings = try XCTUnwrap(response.ratings)
        XCTAssertEqual(ratings.count, 2)

        XCTAssertEqual(ratings[0].source, "csfd")
        XCTAssertEqual(ratings[0].value, 84.0)
        XCTAssertEqual(ratings[0].url, "https://www.csfd.cz/film/12345")

        XCTAssertEqual(ratings[1].source, "douban")
        XCTAssertEqual(ratings[1].value, 9.1)
        XCTAssertEqual(ratings[1].url, "https://movie.douban.com/subject/12345")
    }

    // MARK: - Anti-Spoofing and Filter Tests

    func testAntiSpoofingRejectsBuiltInProviders() {
        XCTAssertTrue(AddonRatingsService.builtInProviders.contains("imdb"))
        XCTAssertTrue(AddonRatingsService.builtInProviders.contains("tmdb"))
        XCTAssertTrue(AddonRatingsService.builtInProviders.contains("tomatoes"))
        XCTAssertTrue(AddonRatingsService.builtInProviders.contains("metacritic"))
        XCTAssertTrue(AddonRatingsService.builtInProviders.contains("trakt"))
        XCTAssertTrue(AddonRatingsService.builtInProviders.contains("letterboxd"))
        XCTAssertTrue(AddonRatingsService.builtInProviders.contains("audience"))
        XCTAssertTrue(AddonRatingsService.builtInProviders.contains("myanimelist"))
        XCTAssertTrue(AddonRatingsService.builtInProviders.contains("mal"))
        XCTAssertTrue(AddonRatingsService.builtInProviders.contains("tvdb"))

        XCTAssertFalse(AddonRatingsService.builtInProviders.contains("csfd"))
        XCTAssertFalse(AddonRatingsService.builtInProviders.contains("kinopoisk"))
    }

    // MARK: - User Settings and Icon Overrides

    func testUserCanEnableDisableAndOverrideIconForAddonRatingSource() {
        let suiteName = "test.ratings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Default is enabled
        XCTAssertTrue(AddonRatingsService.isSourceEnabled("csfd", defaults: defaults))

        // Disable source
        AddonRatingsService.setSourceEnabled("csfd", enabled: false, defaults: defaults)
        XCTAssertFalse(AddonRatingsService.isSourceEnabled("csfd", defaults: defaults))

        // Re-enable source
        AddonRatingsService.setSourceEnabled("csfd", enabled: true, defaults: defaults)
        XCTAssertTrue(AddonRatingsService.isSourceEnabled("csfd", defaults: defaults))

        // Icon override
        XCTAssertNil(AddonRatingsService.iconOverride(for: "csfd", defaults: defaults))
        let overrideUrl = "https://raw.githubusercontent.com/icons/csfd.png"
        AddonRatingsService.setIconOverride(for: "csfd", urlString: overrideUrl, defaults: defaults)
        XCTAssertEqual(AddonRatingsService.iconOverride(for: "csfd", defaults: defaults), overrideUrl)

        // Clear icon override
        AddonRatingsService.setIconOverride(for: "csfd", urlString: nil, defaults: defaults)
        XCTAssertNil(AddonRatingsService.iconOverride(for: "csfd", defaults: defaults))
    }

    // MARK: - NuvioExternalRating Codable Roundtrip

    func testNuvioExternalRatingRoundtrip() throws {
        let rating = NuvioExternalRating(
            source: "csfd",
            value: 84.0,
            url: "https://www.csfd.cz/film/123",
            name: "ČSFD",
            iconUrl: "https://example.com/icon.png",
            max: 100.0
        )

        let data = try JSONEncoder().encode(rating)
        let decoded = try JSONDecoder().decode(NuvioExternalRating.self, from: data)

        XCTAssertEqual(decoded.source, "csfd")
        XCTAssertEqual(decoded.value, 84.0)
        XCTAssertEqual(decoded.url, "https://www.csfd.cz/film/123")
        XCTAssertEqual(decoded.name, "ČSFD")
        XCTAssertEqual(decoded.iconUrl, "https://example.com/icon.png")
        XCTAssertEqual(decoded.max, 100.0)
    }

    func testNuvioExternalRatingDecodesLegacyJsonWithoutOptionalFields() throws {
        let legacyJson = """
        {
            "source": "imdb",
            "value": 8.4
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(NuvioExternalRating.self, from: legacyJson)
        XCTAssertEqual(decoded.source, "imdb")
        XCTAssertEqual(decoded.value, 8.4)
        XCTAssertNil(decoded.url)
        XCTAssertNil(decoded.name)
        XCTAssertNil(decoded.iconUrl)
        XCTAssertNil(decoded.max)
    }
}
