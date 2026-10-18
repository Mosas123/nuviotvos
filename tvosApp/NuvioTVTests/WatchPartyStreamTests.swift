import XCTest
@testable import NuvioTV

final class WatchPartyStreamTests: XCTestCase {
    private let key = "movie|tt1||"
    private let hash = String(repeating: "a", count: 40)

    func testAndroidDefaultsAndMobileBadgePayloadDecode() throws {
        let data = Data(#"{"media_key":"movie|tt1||","url":"https://cdn.example.test/a.mkv","stream_type":"debrid","badges":[{"name":"4K","imageURL":"https://cdn.example.test/4k.png"}],"future":true}"#.utf8)
        let stream = try JSONDecoder().decode(WatchPartyStream.self, from: data)
        XCTAssertEqual(stream.streamType, "debrid")
        XCTAssertEqual(stream.headers, [:])
        XCTAssertEqual(stream.responseHeaders, [:])
        XCTAssertEqual(stream.addonID, "")
        XCTAssertEqual(stream.badges.first?.imageURL, "https://cdn.example.test/4k.png")
        XCTAssertEqual(stream.badges.first?.tagStyle, "")
    }

    func testRoundTripKeepsHeadersMetadataAndInt64Precision() throws {
        let value = WatchPartyStream(mediaKey: key, url: "https://cdn.example.test/video?token=private",
                                     headers: ["Authorization": "Bearer test-only"], responseHeaders: ["Content-Type": "video/x-matroska"],
                                     name: "HD", description: "Movie", addonName: "Addon", addonID: "addon:id",
                                     addonLogo: "https://cdn.example.test/logo.png", filename: "movie.mkv",
                                     videoSize: 9_007_199_254_740_993, bingeGroup: "release", streamType: "debrid",
                                     badges: [WatchPartyStreamBadge(name: "HDR", imageURL: "image", tagColor: "red", tagStyle: "pill", textColor: "white", borderColor: "black")])
        let decoded = try JSONDecoder().decode(WatchPartyStream.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded, value)
        let candidate = try decoded.playbackCandidate()
        XCTAssertEqual(candidate.stream.directURL, value.url)
        XCTAssertEqual(candidate.stream.httpHeaders, value.headers)
        XCTAssertEqual(candidate.stream.videoSize, value.videoSize)
        XCTAssertEqual(candidate.responseHeaders, value.responseHeaders)
        XCTAssertEqual(candidate.metadata.badges, value.badges)
        XCTAssertEqual(candidate.metadata.addonID, "addon:id")
        XCTAssertFalse(candidate.stream.isTorrentStream)
    }

    func testClearUsesExplicitNullAndMissingStreamIsMalformed() throws {
        let encoded = try JSONEncoder().encode(WatchPartyStreamMessage(memberID: "host", stream: nil))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertTrue(object["stream"] is NSNull)
        XCTAssertNil(try JSONDecoder().decode(WatchPartyStreamMessage.self, from: encoded).stream)
        XCTAssertThrowsError(try JSONDecoder().decode(WatchPartyStreamMessage.self, from: Data(#"{"member_id":"host"}"#.utf8)))
    }

    func testHostPayloadUsesResolvedPlaybackURLAndEffectiveHeaders() throws {
        let source = NuvioStream(url: "https://discovery.example.test/stale", name: "HD", description: "Movie", addonName: "Addon",
                                 filename: "movie.mkv", videoSize: 100, bingeGroup: "group", httpHeaders: ["Referer": "stale"])
        let value = try WatchPartyStream.fromPlayback(source, mediaKey: key, resolvedURL: "https://cdn.example.test/current",
                                                     requestHeaders: ["Referer": "effective"], responseHeaders: ["Content-Type": "video/mp4"],
                                                     origin: .directHTTP, addonID: "addon:id")
        XCTAssertEqual(value.url, "https://cdn.example.test/current")
        XCTAssertEqual(value.headers, ["Referer": "effective"])
        XCTAssertEqual(value.responseHeaders, ["Content-Type": "video/mp4"])
        XCTAssertEqual(value.filename, "movie.mkv")
        XCTAssertEqual(value.addonID, "addon:id")
        XCTAssertThrowsError(try WatchPartyStream.fromPlayback(source, mediaKey: key, resolvedURL: value.url,
                                                              requestHeaders: [:], responseHeaders: [:], origin: .serverManaged))
    }

    func testRemoteAndLANLinksAreAcceptedWithoutMakingRequests() {
        for url in ["https://cdn.example.test/a.mkv?token=private", "http://192.168.1.20:8096/video", "https://[2001:db8::1]/video"] {
            XCTAssertTrue(WatchPartyStreamPolicy.isShareableURL(url), url)
        }
    }

    func testLoopbackUnspecifiedAndAlternateNumericFormsAreRejected() {
        for url in ["http://localhost/video", "http://a.localhost/video", "http://127.1/video", "http://127.0.0.1/video",
                    "http://2130706433/video", "http://0x7f000001/video", "http://0.0.0.0/video",
                    "http://[::1]/video", "http://[::]/video", "http://[::ffff:127.0.0.1]/video", "http://[::127.0.0.1]/video"] {
            XCTAssertFalse(WatchPartyStreamPolicy.isShareableURL(url), url)
        }
    }

    func testNonWebCredentialsAndWhitespaceAreRejected() {
        for url in ["file:///movie.mkv", "magnet:?xt=urn:btih:abc", "https://user:password@cdn.example.test/a",
                    " https://cdn.example.test/a", "https://cdn.example.test/a\nInjected", "https:///video", "https://cdn.example.test:99999/a"] {
            XCTAssertFalse(WatchPartyStreamPolicy.isShareableURL(url), url)
        }
    }

    func testHeaderInjectionAndCaseDuplicateNamesAreRejected() {
        for headers in [["Referer": "value\r\nInjected: true"], ["Bad Header": "value"], ["Referer": "a", "referer": "b"]] {
            let value = WatchPartyStream(mediaKey: key, url: "https://cdn.example.test/a", headers: headers)
            XCTAssertThrowsError(try WatchPartyStreamPolicy.validate(value)) { error in
                XCTAssertEqual(error as? WatchPartyStreamError, .invalidHeaders)
            }
        }
    }

    func testOversizedPayloadIsRejectedBeforeSharing() {
        let value = WatchPartyStream(mediaKey: key, url: "https://cdn.example.test/a",
                                     description: String(repeating: "x", count: WatchPartyStreamPolicy.maximumPayloadBytes))
        XCTAssertThrowsError(try WatchPartyStreamPolicy.validate(value)) { error in
            XCTAssertEqual(error as? WatchPartyStreamError, .oversizedPayload)
        }
    }

    func testTorrentHashAndIndexTakePriorityOverMatchingFilename() {
        let candidate = NuvioStream(url: nil, name: "HD", description: nil, addonName: "Addon", infoHash: hash, fileIdx: 2, filename: "same.mkv")
        XCTAssertTrue(WatchPartySourceMatcher.matches(WatchPartySource(infoHash: hash.uppercased(), fileIndex: 2), stream: candidate))
        XCTAssertTrue(WatchPartySourceMatcher.matches(WatchPartySource(infoHash: hash), stream: candidate))
        XCTAssertFalse(WatchPartySourceMatcher.matches(WatchPartySource(infoHash: hash, fileIndex: 3, filename: "same.mkv"), stream: candidate))
        XCTAssertFalse(WatchPartySourceMatcher.matches(WatchPartySource(infoHash: String(repeating: "b", count: 40), filename: "same.mkv"), stream: candidate))
    }

    func testEffectiveTorrentURLAndTrimmedFilenameFallback() {
        let magnet = NuvioStream(url: "magnet:?xt=urn:btih:\(hash)&fileIdx=2", name: nil, description: nil, addonName: nil)
        XCTAssertTrue(WatchPartySourceMatcher.matches(WatchPartySource(infoHash: hash, fileIndex: 2), stream: magnet))
        let direct = NuvioStream(url: "https://cdn.example.test/a", name: "HD", description: nil, addonName: nil, filename: " Movie.2017.MKV ")
        XCTAssertTrue(WatchPartySourceMatcher.matches(WatchPartySource(filename: "movie.2017.mkv"), stream: direct))
        XCTAssertFalse(WatchPartySourceMatcher.matches(WatchPartySource(name: "HD"), stream: direct))
    }

    func testResolverKeepsAmbiguityAndExcludesActionStreams() {
        let direct = NuvioStream(url: "https://cdn.example.test/a", name: nil, description: nil, addonName: nil, filename: "same.mkv")
        let action = NuvioStream(url: "https://cdn.example.test/action", name: nil, description: nil, addonName: nil,
                                 filename: "same.mkv", notPlayable: true)
        let source = WatchPartySource(filename: "same.mkv")
        XCTAssertEqual(WatchPartySourceMatcher.resolve(source, streams: [action, direct]), .unique(index: 1))
        XCTAssertEqual(WatchPartySourceMatcher.resolve(source, streams: [direct, action, direct]), .ambiguous(indices: [0, 2]))
        XCTAssertEqual(WatchPartySourceMatcher.resolve(WatchPartySource(name: "HD"), streams: [direct]), .none)
    }
}
