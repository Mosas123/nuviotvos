import XCTest
@testable import NuvioTV

final class WatchPartyLaunchTests: XCTestCase {
    func testMovieOwnSelectionMatchesRoomWithoutComparingReceivedURLs() throws {
        let room = WatchPartyMedia(type: "movie", metaID: "tt1", metaType: "movie", title: "Host title")
        let own = WatchPartyMedia(type: "movie", metaID: "tt1", metaType: "MOVIE", title: "Localized title")
        XCTAssertNoThrow(try WatchPartyLaunchPolicy.validateSelection(own, room: room))
    }

    func testDifferentTitleWithSameDisplayNameIsRejected() {
        let room = WatchPartyMedia(type: "movie", metaID: "tt1", metaType: "movie", title: "Same name")
        let own = WatchPartyMedia(type: "movie", metaID: "tt2", metaType: "movie", title: "Same name")
        XCTAssertThrowsError(try WatchPartyLaunchPolicy.validateSelection(own, room: room))
    }

    func testDifferentEpisodeOfSameSeriesIsRejected() {
        let room = WatchPartyMedia(type: "series", metaID: "tt1", metaType: "series", season: 1, episode: 2)
        let own = WatchPartyMedia(type: "series", metaID: "tt1", metaType: "series", season: 1, episode: 3)
        XCTAssertThrowsError(try WatchPartyLaunchPolicy.validateSelection(own, room: room))
    }

    func testSeriesWithoutResolvedEpisodeCannotLaunch() {
        let own = WatchPartyMedia(type: "series", metaID: "tt1", metaType: "series")
        XCTAssertThrowsError(try WatchPartyLaunchPolicy.validate(own))
    }

    func testSpecialsHaveExplicitSeasonZeroAndPositiveEpisode() {
        XCTAssertNoThrow(try WatchPartyLaunchPolicy.validate(
            WatchPartyMedia(type: "series", metaID: "tt1", metaType: "series", season: 0, episode: 1)))
        XCTAssertThrowsError(try WatchPartyLaunchPolicy.validate(
            WatchPartyMedia(type: "series", metaID: "tt1", metaType: "series", season: 0, episode: 0)))
    }

    func testLiveAndMalformedIdentityCannotBecomePartyPlayback() {
        for media in [WatchPartyMedia(type: "live", metaID: "live1", metaType: "live"),
                      WatchPartyMedia(type: "movie", metaID: "movie|fake||", metaType: "movie"),
                      WatchPartyMedia(type: "movie", metaID: "", metaType: "movie")] {
            XCTAssertThrowsError(try WatchPartyLaunchPolicy.validate(media))
        }
    }
}
