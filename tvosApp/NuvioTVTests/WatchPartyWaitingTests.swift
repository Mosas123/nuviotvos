import XCTest
@testable import NuvioTV

final class WatchPartyWaitingTests: XCTestCase {
    private let media = WatchPartyMedia(type: "movie", metaID: "tt1", metaType: "movie")
    private var members: [WatchPartyMember] {
        [WatchPartyMember(id: "me", displayName: "Me"), WatchPartyMember(id: "other", displayName: "Other")]
    }
    private func state(paused: Bool = false, waiting: Bool = false) -> WatchPartyPlayback {
        WatchPartyPlayback(seq: 1, memberID: "me", paused: paused, positionMs: 1_000, at: 20_000, mediaKey: media.key, waiting: waiting)
    }
    private func presence(_ status: WatchPartyMemberStatus = .buffering, key: String = "movie|tt1||") -> [String: WatchPartyPresence] {
        ["other": WatchPartyPresence(memberID: "other", status: status, mediaKey: key)]
    }
    private func decide(_ coordinator: inout WatchPartyWaitingCoordinator, state: WatchPartyPlayback,
                        presence: [String: WatchPartyPresence], uptime: TimeInterval = 10, connected: Bool = true,
                        host: String = "me", hostOnly: Bool = false) -> WatchPartyWaitingDecision? {
        coordinator.decision(party: WatchPartyInfo(id: "room", code: "ABC234", hostMemberID: host, hostOnly: hostOnly, media: media),
                             memberID: "me", members: members, presence: presence, playback: state,
                             connected: connected, uptime: uptime, serverNowMs: 21_000)
    }

    func testBufferingMemberPausesAtProjectedRoomPosition() {
        var coordinator = WatchPartyWaitingCoordinator()
        XCTAssertEqual(decide(&coordinator, state: state(), presence: presence()), .pause(positionMs: 2_000))
    }

    func testBehindReadyAndOtherMediaDoNotBlockRoom() {
        var coordinator = WatchPartyWaitingCoordinator()
        XCTAssertNil(decide(&coordinator, state: state(), presence: presence(.behind)))
        XCTAssertNil(decide(&coordinator, state: state(), presence: presence(.ready)))
        XCTAssertNil(decide(&coordinator, state: state(), presence: presence(.buffering, key: "other")))
    }

    func testHostOnlyDoesNotElectGuestButSharedControlCanFallBack() {
        var coordinator = WatchPartyWaitingCoordinator()
        XCTAssertNil(decide(&coordinator, state: state(), presence: presence(), host: "missing", hostOnly: true))
        XCTAssertEqual(decide(&coordinator, state: state(), presence: presence(), host: "missing"), .pause(positionMs: 2_000))
        XCTAssertNil(decide(&coordinator, state: state(), presence: presence(), host: "other"))
    }

    func testTimeoutIsStrictAndReadyRearmsPreviouslyIgnoredMember() {
        var coordinator = WatchPartyWaitingCoordinator()
        let waiting = state(paused: true, waiting: true)
        XCTAssertNil(decide(&coordinator, state: waiting, presence: presence(), uptime: 10))
        XCTAssertNil(decide(&coordinator, state: waiting, presence: presence(), uptime: 25))
        XCTAssertEqual(decide(&coordinator, state: waiting, presence: presence(), uptime: 26), .resume(positionMs: 1_000))
        coordinator.accepted(previous: waiting, next: state(), mediaKey: media.key, presence: presence(), uptime: 26)
        XCTAssertEqual(coordinator.ignoredMemberIDs, ["other"])
        XCTAssertNil(decide(&coordinator, state: state(), presence: presence(), uptime: 30))
        coordinator.memberReady("other")
        XCTAssertEqual(decide(&coordinator, state: state(), presence: presence(), uptime: 30), .pause(positionMs: 2_000))
    }

    func testManualPauseNeverAutoResumes() {
        var coordinator = WatchPartyWaitingCoordinator()
        XCTAssertNil(decide(&coordinator, state: state(paused: true), presence: [:], uptime: 100))
    }

    func testResumeGraceIsThreeSecondsAndDoesNotIgnoreNewWaiter() {
        var coordinator = WatchPartyWaitingCoordinator()
        coordinator.accepted(previous: state(paused: true), next: state(), mediaKey: media.key, presence: presence(), uptime: 0)
        XCTAssertNil(decide(&coordinator, state: state(), presence: presence(), uptime: 3))
        XCTAssertEqual(decide(&coordinator, state: state(), presence: presence(), uptime: 3.5), .pause(positionMs: 2_000))
    }

    func testMediaResetClearsIgnoredMembersAndOldMediaCannotCoordinate() {
        var coordinator = WatchPartyWaitingCoordinator()
        coordinator.accepted(previous: state(paused: true, waiting: true), next: state(), mediaKey: media.key, presence: presence(), uptime: 0)
        coordinator.reset()
        XCTAssertTrue(coordinator.ignoredMemberIDs.isEmpty)
        var wrongMedia = state()
        wrongMedia.mediaKey = "other"
        XCTAssertNil(decide(&coordinator, state: wrongMedia, presence: presence()))
        XCTAssertEqual(decide(&coordinator, state: state(), presence: presence()), .pause(positionMs: 2_000))
    }

    func testOfflineTimeDoesNotCountAsConnectedWaitingLimit() {
        var coordinator = WatchPartyWaitingCoordinator()
        let waiting = state(paused: true, waiting: true)
        XCTAssertNil(decide(&coordinator, state: waiting, presence: presence(), uptime: 0))
        XCTAssertNil(decide(&coordinator, state: waiting, presence: presence(), uptime: 99, connected: false))
        coordinator.disconnected()
        XCTAssertNil(decide(&coordinator, state: waiting, presence: presence(), uptime: 100))
        XCTAssertNil(decide(&coordinator, state: waiting, presence: presence(), uptime: 115))
        XCTAssertEqual(decide(&coordinator, state: waiting, presence: presence(), uptime: 116), .resume(positionMs: 1_000))
    }
}
