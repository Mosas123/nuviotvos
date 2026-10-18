import XCTest
@testable import NuvioTV

final class WatchPartyWireTests: XCTestCase {
    private func decode<T: Decodable>(_ text: String, as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: Data(text.utf8))
    }

    func testAndroidMediaDefaultsAndCanonicalEpisodeKey() throws {
        let media = try decode(#"{"type":"series","meta_id":"tt1","meta_type":"SERIES","season":2,"episode":3,"unknown":true}"#, as: WatchPartyMedia.self)
        XCTAssertEqual(media.key, "series|tt1|2|3")
        XCTAssertEqual(media.title, "")
        var changedSource = media
        changedSource.source = WatchPartySource(filename: "different.mkv")
        XCTAssertEqual(changedSource.key, media.key)
        XCTAssertEqual(WatchPartyMedia(type: "movie", metaID: "tt1", metaType: "movie").key, "movie|tt1||")
    }

    func testMinimalAndroidPlaybackDefaultsAndInt64RoundTrip() throws {
        let state = try decode(#"{"seq":9007199254740993,"paused":false,"position_ms":10000,"at":1000000}"#, as: WatchPartyPlayback.self)
        XCTAssertEqual(state.seq, 9_007_199_254_740_993)
        XCTAssertEqual(state.rate, 1)
        XCTAssertFalse(state.waiting)
        XCTAssertNil(state.memberID)
        XCTAssertEqual(try JSONDecoder().decode(WatchPartyPlayback.self, from: JSONEncoder().encode(state)), state)
    }

    func testMalformedRateAndRequiredFieldsAreRejected() {
        XCTAssertThrowsError(try decode(#"{"seq":1,"paused":false,"position_ms":0,"at":1,"rate":0}"#, as: WatchPartyPlayback.self))
        XCTAssertThrowsError(try decode(#"{"seq":1,"paused":false,"position_ms":0}"#, as: WatchPartyPlayback.self))
        XCTAssertThrowsError(try decode(#"{"type":"movie","meta_id":"tt1"}"#, as: WatchPartyMedia.self))
    }

    func testSnapshotDefaultsDoNotTurnErrorsIntoAnEmptySuccessfulRoom() throws {
        let missing = try decode(#"{"error":"party_not_found"}"#, as: WatchPartySnapshot.self)
        XCTAssertNil(missing.party)
        XCTAssertTrue(missing.members.isEmpty)
        XCTAssertEqual(WatchPartyFailure(serverCode: missing.error), .notFound)
        XCTAssertEqual(WatchPartyFailure(serverCode: "not_member"), .removed)
        XCTAssertEqual(WatchPartyFailure(serverCode: "future_error"), .network)
        XCTAssertNil(WatchPartyFailure(serverCode: nil))
    }

    func testAndroidRoomDefaultsAndPresence() throws {
        let room = try decode(#"{"id":"room","code":"ABC234","media":{"type":"movie","meta_id":"tt1","meta_type":"movie"}}"#, as: WatchPartyInfo.self)
        XCTAssertFalse(room.hostOnly)
        XCTAssertEqual(room.maxMembers, 3)
        let presence = try decode(#"{"member_id":"a"}"#, as: WatchPartyPresence.self)
        XCTAssertEqual(presence.status, .browsing)
        XCTAssertEqual(try decode(#"{"member_id":"a","status":"behind","behind_ms":5000}"#, as: WatchPartyPresence.self).behindMs, 5_000)
    }

    func testPreviewUsesServerLimitRatherThanAssumingThreeSeats() throws {
        let preview = try decode(#"{"members":4,"max_members":5}"#, as: WatchPartyPreview.self)
        XCTAssertFalse(preview.isFull)
        XCTAssertTrue(try decode(#"{"members":5,"max_members":5}"#, as: WatchPartyPreview.self).isFull)
        XCTAssertFalse(try decode("{}", as: WatchPartyPreview.self).isFull)
    }

    func testCodeNormalizationMatchesAndroidAndNeverTruncatesAnInvalidLongCode() {
        XCTAssertEqual(WatchPartyCode.normalize("abc-234"), "ABC234")
        XCTAssertEqual(WatchPartyCode.formatted("abc234"), "ABC 234")
        XCTAssertTrue(WatchPartyCode.isValid("abc 234"))
        XCTAssertFalse(WatchPartyCode.isValid("ABC2345"))
        XCTAssertEqual(WatchPartyCode.normalize("01ILO!"), "L")
    }
}
