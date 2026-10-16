import XCTest
@testable import NuvioTV

final class PosterCardStyleSyncTests: XCTestCase {
    func testCornerRadiusExportMapping() {
        XCTAssertEqual(PosterCardStyleSyncMapper.cornerRadiusDp(for: "Sharp (0pt)"), 0)
        XCTAssertEqual(PosterCardStyleSyncMapper.cornerRadiusDp(for: "Subtle (8pt)"), 4)
        XCTAssertEqual(PosterCardStyleSyncMapper.cornerRadiusDp(for: "Classic (16pt)"), 8)
        XCTAssertEqual(PosterCardStyleSyncMapper.cornerRadiusDp(for: "Rounded (22pt)"), 12)
        XCTAssertEqual(PosterCardStyleSyncMapper.cornerRadiusDp(for: "Pill (28pt)"), 16)
        XCTAssertEqual(PosterCardStyleSyncMapper.cornerRadiusDp(for: nil), 8)
    }

    func testCornerRadiusImportMapping() {
        XCTAssertEqual(PosterCardStyleSyncMapper.cornerRadiusOption(for: 0), .sharp)
        XCTAssertEqual(PosterCardStyleSyncMapper.cornerRadiusOption(for: -1), .sharp)
        XCTAssertEqual(PosterCardStyleSyncMapper.cornerRadiusOption(for: 4), .subtle)
        XCTAssertEqual(PosterCardStyleSyncMapper.cornerRadiusOption(for: 6), .subtle)
        XCTAssertEqual(PosterCardStyleSyncMapper.cornerRadiusOption(for: 8), .classic)
        XCTAssertEqual(PosterCardStyleSyncMapper.cornerRadiusOption(for: 10), .classic)
        XCTAssertEqual(PosterCardStyleSyncMapper.cornerRadiusOption(for: 12), .rounded)
        XCTAssertEqual(PosterCardStyleSyncMapper.cornerRadiusOption(for: 14), .rounded)
        XCTAssertEqual(PosterCardStyleSyncMapper.cornerRadiusOption(for: 16), .pill)
        XCTAssertEqual(PosterCardStyleSyncMapper.cornerRadiusOption(for: 24), .pill)
    }

    func testCardSizeExportMapping() {
        XCTAssertEqual(PosterCardStyleSyncMapper.widthDp(for: "Compact"), 104)
        XCTAssertEqual(PosterCardStyleSyncMapper.widthDp(for: "Dense"), 112)
        XCTAssertEqual(PosterCardStyleSyncMapper.widthDp(for: "Standard"), 120)
        XCTAssertEqual(PosterCardStyleSyncMapper.widthDp(for: "Balanced"), 126)
        XCTAssertEqual(PosterCardStyleSyncMapper.widthDp(for: "Comfort"), 134)
        XCTAssertEqual(PosterCardStyleSyncMapper.widthDp(for: "Large"), 140)
    }

    func testCardSizeImportMapping() {
        XCTAssertEqual(PosterCardStyleSyncMapper.cardSizeOption(for: 104), .compact)
        XCTAssertEqual(PosterCardStyleSyncMapper.cardSizeOption(for: 112), .dense)
        XCTAssertEqual(PosterCardStyleSyncMapper.cardSizeOption(for: 120), .standard)
        XCTAssertEqual(PosterCardStyleSyncMapper.cardSizeOption(for: 126), .balanced)
        XCTAssertEqual(PosterCardStyleSyncMapper.cardSizeOption(for: 134), .comfort)
        XCTAssertEqual(PosterCardStyleSyncMapper.cardSizeOption(for: 140), .large)
    }

    func testExportPayloadSerialization() {
        let jsonString = PosterCardStyleSyncMapper.exportPayload(
            cardCornerRadius: "Sharp (0pt)",
            cardSize: "Balanced",
            existingPayload: nil
        )
        XCTAssertFalse(jsonString.isEmpty)

        guard let data = jsonString.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            XCTFail("Failed to parse exported JSON payload")
            return
        }

        XCTAssertEqual(dict["cornerRadiusDp"] as? Int, 0)
        XCTAssertEqual(dict["widthDp"] as? Int, 126)
        XCTAssertEqual(dict["heightDp"] as? Int, 189)
        XCTAssertEqual(dict["catalogLandscapeModeEnabled"] as? Bool, false)
        XCTAssertEqual(dict["hideLabelsEnabled"] as? Bool, false)
    }

    func testExportPayloadPreservesExistingCustomFlags() {
        let existing = "{\"catalogLandscapeModeEnabled\":true,\"hideLabelsEnabled\":true}"
        let jsonString = PosterCardStyleSyncMapper.exportPayload(
            cardCornerRadius: "Pill (28pt)",
            cardSize: "Large",
            existingPayload: existing
        )

        guard let data = jsonString.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            XCTFail("Failed to parse exported JSON payload")
            return
        }

        XCTAssertEqual(dict["cornerRadiusDp"] as? Int, 16)
        XCTAssertEqual(dict["widthDp"] as? Int, 140)
        XCTAssertEqual(dict["catalogLandscapeModeEnabled"] as? Bool, true)
        XCTAssertEqual(dict["hideLabelsEnabled"] as? Bool, true)
    }

    func testImportPayloadDeserialization() {
        let remoteJson = "{\"cornerRadiusDp\":0,\"widthDp\":126,\"heightDp\":189}"
        let (radiusOpt, sizeOpt) = PosterCardStyleSyncMapper.importPayload(remoteJson)
        XCTAssertEqual(radiusOpt, .sharp)
        XCTAssertEqual(sizeOpt, .balanced)
    }

    func testImportPayloadDictionary() {
        let dict: [String: Any] = [
            "cornerRadiusDp": 12,
            "widthDp": 104
        ]
        let (radiusOpt, sizeOpt) = PosterCardStyleSyncMapper.importPayload(dict)
        XCTAssertEqual(radiusOpt, .rounded)
        XCTAssertEqual(sizeOpt, .compact)
    }

    func testCustomPosterLayoutExportUsesTypedValuesAndPreservesSiblingSettings() {
        let existing: [String: Any] = [
            "discover_location": ["type": "string", "value": "Search"],
            "search_discover_enabled": ["type": "boolean", "value": true]
        ]
        let pattern = "https://pictorium.elfhosted.com/api/poster/{type}/{tmdb_id|imdb_id}?u=test-space&shape={shape}"
        let exported = CustomPosterSettingsSyncMapper.export(
            pattern: pattern,
            enabledScreens: "home,search",
            existing: existing
        )

        XCTAssertEqual((exported[CustomPosterSettingsSyncMapper.patternKey] as? [String: Any])?["type"] as? String, "string")
        XCTAssertEqual((exported[CustomPosterSettingsSyncMapper.patternKey] as? [String: Any])?["value"] as? String, pattern)
        XCTAssertEqual((exported[CustomPosterSettingsSyncMapper.enabledScreensKey] as? [String: Any])?["type"] as? String, "string")
        XCTAssertEqual((exported[CustomPosterSettingsSyncMapper.enabledScreensKey] as? [String: Any])?["value"] as? String, "home,search")
        XCTAssertEqual((exported["discover_location"] as? [String: Any])?["value"] as? String, "Search")
        XCTAssertEqual((exported["search_discover_enabled"] as? [String: Any])?["value"] as? Bool, true)
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.customPosterURLPattern))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.customPosterEnabledScreens))
    }

    func testCustomPosterLayoutExportUsesAndroidCompatibleAllScreenKeys() {
        let allScreens = CustomPosterScreen.storageValue(for: Set(CustomPosterScreen.allCases))
        let exported = CustomPosterSettingsSyncMapper.export(
            pattern: "",
            enabledScreens: allScreens,
            existing: nil
        )

        XCTAssertEqual(
            (exported[CustomPosterSettingsSyncMapper.enabledScreensKey] as? [String: Any])?["value"] as? String,
            "home,continue_watching,collections,library,search,details,tv_recommendations"
        )
        XCTAssertNotEqual(
            (exported[CustomPosterSettingsSyncMapper.enabledScreensKey] as? [String: Any])?["value"] as? String,
            "all"
        )
    }

    func testCustomPosterLayoutImportDefaultsMissingScreensToAll() {
        let remote: [String: Any] = [
            CustomPosterSettingsSyncMapper.patternKey: ["type": "string", "value": "https://example.com/{tmdb_id}"]
        ]
        let current = CustomPosterSettingsSyncMapper.Values(
            pattern: "https://local.example/{imdb_id}",
            enabledScreens: "home,library"
        )
        let imported = CustomPosterSettingsSyncMapper.importing(remote, preserving: current)

        XCTAssertEqual(imported.pattern, "https://example.com/{tmdb_id}")
        XCTAssertEqual(
            imported.enabledScreens,
            "home,continue_watching,collections,library,search,details,tv_recommendations"
        )
    }

    func testCustomPosterLayoutImportPreservesLocalConfigWhenBothFieldsAreAbsent() {
        let remote: [String: Any] = [
            "discover_location": ["type": "string", "value": "Search"]
        ]
        let current = CustomPosterSettingsSyncMapper.Values(
            pattern: "https://local.example/{imdb_id}",
            enabledScreens: "home,library"
        )

        XCTAssertEqual(CustomPosterSettingsSyncMapper.importing(remote, preserving: current), current)
        XCTAssertEqual(
            CustomPosterSettingsSyncMapper.importing(nil, preserving: current),
            current
        )
    }
}
