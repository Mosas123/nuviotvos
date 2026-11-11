import XCTest
@testable import NuvioTV

/// AniList and MAL keep the logged-in account's lists in memory; another profile may use another
/// account, so switching profiles must not carry them over.
final class AnimeProfileSwitchTests: XCTestCase {
    private var previousProfileID: String?
    private var previousIsPrimary = false

    override func setUp() {
        super.setUp()
        previousProfileID = ProfileSettings.activeProfileID
        previousIsPrimary = ProfileSettings.isPrimaryProfileStore(ProfileSettings.current)
    }

    override func tearDown() {
        AniListAccount.clearStates()
        if let previousProfileID {
            ProfileSettings.setActiveProfile(previousProfileID, isPrimary: previousIsPrimary)
        } else {
            ProfileSettings.clearActiveProfile()
        }
        super.tearDown()
    }

    func testSwitchingProfileForgetsAniListEntries() {
        ProfileSettings.setActiveProfile("anime-switch-a-\(UUID().uuidString)", isPrimary: false)
        AniListAccount.store(entries: [], media: [], asked: [42])
        XCTAssertTrue(AniListAccount.hasAsked(42))

        ProfileSettings.setActiveProfile("anime-switch-b-\(UUID().uuidString)", isPrimary: false)

        XCTAssertFalse(AniListAccount.hasAsked(42))
    }

    func testScrobbleWriteIsDroppedAfterAProfileSwitch() {
        let asking = "anime-scrobble-a-\(UUID().uuidString)"
        ProfileSettings.setActiveProfile(asking, isPrimary: false)
        XCTAssertTrue(AniListScrobbler.isStillActive(asking, "test"))

        ProfileSettings.setActiveProfile("anime-scrobble-b-\(UUID().uuidString)", isPrimary: false)

        XCTAssertFalse(AniListScrobbler.isStillActive(asking, "test"))
    }
}
