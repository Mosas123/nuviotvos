import XCTest
@testable import NuvioTV

final class WatchPartyFoundationTests: XCTestCase {
    private func playback(seq: Int64 = 1, memberID: String? = "a", paused: Bool = false,
                          positionMs: Int64 = 10_000, rate: Float = 1, at: Int64 = 1_000_000,
                          mediaKey: String? = "movie|tt1||", waiting: Bool = false) -> WatchPartyPlayback {
        WatchPartyPlayback(seq: seq, memberID: memberID, paused: paused, positionMs: positionMs,
                           rate: rate, at: at, mediaKey: mediaKey, waiting: waiting)
    }

    func testGuestSharedSourceNoticeNeverExposesURLOrHeaders() {
        let stream = WatchPartyStream(
            mediaKey: "movie|tt1||",
            url: "https://stream.example.test/play?token=PRIVATE_LINK_TOKEN",
            headers: ["Authorization": "Bearer PRIVATE_HEADER_TOKEN"],
            name: "PRIVATE_SOURCE_NAME"
        )
        let notice = WatchPartySharedSourceNotice.text(
            hostName: "Alex", stream: stream, mediaKey: "movie|tt1||",
            isGuest: true, connected: true
        )
        XCTAssertNotNil(notice)
        XCTAssertTrue(notice?.contains("Alex") == true)
        XCTAssertFalse(notice?.contains("PRIVATE_LINK_TOKEN") == true)
        XCTAssertFalse(notice?.contains("PRIVATE_HEADER_TOKEN") == true)
        XCTAssertFalse(notice?.contains("PRIVATE_SOURCE_NAME") == true)
        XCTAssertNil(WatchPartySharedSourceNotice.text(
            hostName: "Alex", stream: stream, mediaKey: "movie|different||",
            isGuest: true, connected: true
        ))
        XCTAssertNil(WatchPartySharedSourceNotice.text(
            hostName: "Alex", stream: stream, mediaKey: "movie|tt1||",
            isGuest: false, connected: true
        ))
        XCTAssertNil(WatchPartySharedSourceNotice.text(
            hostName: "Alex", stream: stream, mediaKey: "movie|tt1||",
            isGuest: true, connected: false
        ))
    }

    func testRoomSelectionRejectsWrongMovieAndWrongEpisode() throws {
        let roomMovie = WatchPartyMedia(type: "movie", metaID: "tt001", metaType: "movie", title: "A")
        let sameMovie = WatchPartyMedia(type: "movie", metaID: "tt001", metaType: "movie", title: "Different display title")
        let wrongMovie = WatchPartyMedia(type: "movie", metaID: "tt002", metaType: "movie", title: "A")
        XCTAssertNoThrow(try WatchPartyLaunchPolicy.validateSelection(sameMovie, room: roomMovie))
        XCTAssertThrowsError(try WatchPartyLaunchPolicy.validateSelection(wrongMovie, room: roomMovie))

        let roomEpisode = WatchPartyMedia(type: "series", metaID: "ttSeries", metaType: "series",
                                          season: 2, episode: 3, title: "Series")
        let correctEpisode = WatchPartyMedia(type: "series", metaID: "ttSeries", metaType: "series",
                                             season: 2, episode: 3, title: "Renamed")
        let wrongEpisode = WatchPartyMedia(type: "series", metaID: "ttSeries", metaType: "series",
                                           season: 2, episode: 4, title: "Series")
        XCTAssertNoThrow(try WatchPartyLaunchPolicy.validateSelection(correctEpisode, room: roomEpisode))
        XCTAssertThrowsError(try WatchPartyLaunchPolicy.validateSelection(wrongEpisode, room: roomEpisode))
        XCTAssertThrowsError(try WatchPartyLaunchPolicy.validateSelection(roomMovie, room: roomEpisode))
    }

    func testTimelineRatePauseDurationAndClockSkewMatchAndroid() {
        XCTAssertEqual(WatchPartyPolicy.expectedPosition(playback(rate: 1.5), nowMs: 1_002_000), 13_000)
        XCTAssertEqual(WatchPartyPolicy.expectedPosition(playback(paused: true), nowMs: 1_500_000), 10_000)
        XCTAssertEqual(WatchPartyPolicy.expectedPosition(playback(positionMs: 99_000), nowMs: 1_010_000, durationMs: 100_000), 100_000)
        XCTAssertEqual(WatchPartyPolicy.expectedPosition(playback(), nowMs: 999_000), 10_000)
    }

    func testSequenceTieUsesKotlinUTF16OrderingAndIgnoresDuplicates() {
        XCTAssertTrue(WatchPartyPolicy.isNewer(playback(seq: 3), than: playback(seq: 2)))
        XCTAssertFalse(WatchPartyPolicy.isNewer(playback(seq: 2), than: playback(seq: 3)))
        XCTAssertTrue(WatchPartyPolicy.isNewer(playback(memberID: "bbb"), than: playback(memberID: "aaa")))
        XCTAssertFalse(WatchPartyPolicy.isNewer(playback(), than: playback()))
        XCTAssertTrue(WatchPartyPolicy.isNewer(playback(memberID: "a"), than: playback(memberID: nil)))
        // Kotlin compares the surrogate 0xD800 before 0xE000, unlike scalar-value order.
        XCTAssertTrue(WatchPartyPolicy.isNewer(playback(memberID: "\u{E000}"), than: playback(memberID: "\u{10000}")))
    }

    func testNudgeDirectionHysteresisAndThresholdEdges() {
        func correction(_ local: Int64, nudging: Bool = false) -> WatchPartyCorrection {
            WatchPartyPolicy.correction(localPositionMs: local, expectedPositionMs: 10_000, playback: playback(), nudging: nudging)
        }
        XCTAssertEqual(correction(10_250), .inSync)
        XCTAssertEqual(correction(10_251), .nudge(rate: 0.95))
        XCTAssertEqual(correction(9_749), .nudge(rate: 1.05))
        XCTAssertEqual(correction(10_080, nudging: true), .inSync)
        XCTAssertEqual(correction(10_081, nudging: true), .nudge(rate: 0.95))
        XCTAssertEqual(correction(11_500), .nudge(rate: 0.95))
        XCTAssertEqual(correction(11_501), .seek(positionMs: 10_000))
    }

    func testPausedRoomDoesNotNudge() {
        let state = playback(paused: true)
        XCTAssertEqual(WatchPartyPolicy.correction(localPositionMs: 10_500, expectedPositionMs: 10_000, playback: state, nudging: false), .inSync)
        XCTAssertEqual(WatchPartyPolicy.correction(localPositionMs: 10_501, expectedPositionMs: 10_000, playback: state, nudging: true), .seek(positionMs: 10_000))
    }

    func testHostAbsenceRespectsHostOnlyAndServerMemberOrder() {
        let members = [WatchPartyMember(id: "older", displayName: "Older"), WatchPartyMember(id: "me", displayName: "Me")]
        XCTAssertEqual(WatchPartyPolicy.coordinatorID(memberID: "me", hostMemberID: "host", hostOnly: false,
                                                     members: members, onlineMemberIDs: ["host", "older"]), "host")
        XCTAssertEqual(WatchPartyPolicy.coordinatorID(memberID: "me", hostMemberID: "host", hostOnly: false,
                                                     members: members, onlineMemberIDs: ["older"]), "older")
        XCTAssertEqual(WatchPartyPolicy.coordinatorID(memberID: "me", hostMemberID: "host", hostOnly: true,
                                                     members: members, onlineMemberIDs: ["older"]), "host")
    }

    func testBehindModeDoesNotBlockTheRoom() {
        XCTAssertEqual(WatchPartyPolicy.ownSeek(targetMs: 7_999, partyPositionMs: 10_000, behind: false), .behind(positionMs: 7_999))
        XCTAssertEqual(WatchPartyPolicy.ownSeek(targetMs: 8_000, partyPositionMs: 10_000, behind: false), .blocked)
        XCTAssertEqual(WatchPartyPolicy.ownSeek(targetMs: 10_000, partyPositionMs: 10_000, behind: true), .catchUp)
        XCTAssertFalse(WatchPartyPolicy.shouldRejoin(gapMs: 1_000, playing: false))
        XCTAssertTrue(WatchPartyPolicy.shouldRejoin(gapMs: 2_000, playing: true))
        XCTAssertEqual(WatchPartyPolicy.reportedGap(7_499), 5_000)
        XCTAssertEqual(WatchPartyPolicy.reportedGap(7_500), 10_000)
        let presence = [
            "loading": WatchPartyPresence(memberID: "loading", status: .loading, mediaKey: "m"),
            "behind": WatchPartyPresence(memberID: "behind", status: .behind, mediaKey: "m"),
            "other": WatchPartyPresence(memberID: "other", status: .buffering, mediaKey: "other"),
            "ignored": WatchPartyPresence(memberID: "ignored", status: .buffering, mediaKey: "m")
        ]
        XCTAssertEqual(WatchPartyPolicy.waitingMemberIDs(mediaKey: "m", presence: presence, ignored: ["ignored"]), ["loading"])
    }

    func testNoticesIgnoreWaitingMediaChangesAndNormalAdvancement() {
        XCTAssertNil(WatchPartyPolicy.action(previous: nil, next: playback()))
        XCTAssertNil(WatchPartyPolicy.action(previous: playback(), next: playback(waiting: true)))
        XCTAssertNil(WatchPartyPolicy.action(previous: playback(), next: playback(mediaKey: "other")))
        XCTAssertNil(WatchPartyPolicy.action(previous: playback(), next: playback(positionMs: 12_000, at: 1_002_000)))
        XCTAssertEqual(WatchPartyPolicy.action(previous: playback(), next: playback(paused: true)), .paused)
        XCTAssertEqual(WatchPartyPolicy.action(previous: playback(paused: true), next: playback()), .resumed)
        XCTAssertEqual(WatchPartyPolicy.action(previous: playback(), next: playback(rate: 1.5)), .speed)
        XCTAssertEqual(WatchPartyPolicy.action(previous: playback(), next: playback(positionMs: 20_000)), .seeked)
    }

    func testExtremeWireTimesDoNotOverflow() {
        XCTAssertEqual(WatchPartyPolicy.expectedPosition(playback(positionMs: .max, at: .min), nowMs: .max), .max)
        XCTAssertEqual(WatchPartyPolicy.correction(localPositionMs: .min, expectedPositionMs: .max,
                                                  playback: playback(), nudging: false), .seek(positionMs: .max))
        XCTAssertEqual(WatchPartyPolicy.reportedGap(.max), .max)
        XCTAssertEqual(WatchPartyPolicy.expectedPosition(playback(paused: true, positionMs: -1), nowMs: 0), 0)
    }

    func testClockChoosesFastestRTTAndUsesMonotonicTimeAfterAnchoring() {
        var uptime: TimeInterval = 10
        var wallMs: Int64 = 500
        var clock = WatchPartyClock(uptime: { uptime }, wallTimeMs: { wallMs })
        XCTAssertEqual(clock.nowMs(), 500)
        let sent = clock.mark()
        uptime = 11
        XCTAssertTrue(clock.addSample(serverMs: 20_000, sentAt: sent))
        XCTAssertEqual(clock.nowMs(), 20_500)
        let fast = clock.mark()
        uptime = 11.25
        XCTAssertTrue(clock.addSample(serverMs: 21_000, sentAt: fast))
        XCTAssertEqual(clock.nowMs(), 21_125)
        wallMs = -99_999
        uptime = 12.25
        XCTAssertEqual(clock.nowMs(), 22_125)
        XCTAssertFalse(clock.addSample(serverMs: 999_999, sentAt: 11))
        XCTAssertFalse(clock.addSample(serverMs: 0, sentAt: .nan))
        clock.reset()
        XCTAssertFalse(clock.isSynced)
        XCTAssertEqual(clock.nowMs(), wallMs)
    }

    func testClockIsResettableAcrossContextsAndSaturates() {
        var uptime: TimeInterval = 0
        var clock = WatchPartyClock(uptime: { uptime }, wallTimeMs: { 0 })
        uptime = 1
        XCTAssertTrue(clock.addSample(serverMs: .max, sentAt: 0))
        XCTAssertEqual(clock.nowMs(), .max)
        clock.reset()
        XCTAssertTrue(clock.addSample(serverMs: 100, sentAt: 0))
        XCTAssertEqual(clock.nowMs(), 600)
    }
}
