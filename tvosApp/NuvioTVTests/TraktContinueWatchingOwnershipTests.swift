import XCTest
@testable import NuvioTV

final class TraktContinueWatchingOwnershipTests: XCTestCase {
    private var profileA = ""
    private var profileB = ""
    private var previousSettingsProfileID: String?
    private var previousSettingsProfileIsPrimary = false
    private var previousContinueWatchingProfileID: String?

    override func setUp() {
        super.setUp()
        previousSettingsProfileID = ProfileSettings.activeProfileID
        previousSettingsProfileIsPrimary = ProfileSettings.isPrimaryProfileStore(ProfileSettings.current)
        previousContinueWatchingProfileID = ContinueWatchingStore.activeProfileId
        profileA = "trakt-cw-a-\(UUID().uuidString)"
        profileB = "trakt-cw-b-\(UUID().uuidString)"
        activate(profileA)
    }

    override func tearDown() async throws {
        await MainActor.run {
            for profileID in [profileA, profileB] {
                activate(profileID)
                TraktProgressService.forgetLocalPlayback(meta: checkpointMeta, notify: false)
                TraktProgressService.forgetLocalPlayback(meta: remoteMeta, notify: false)
                UserDefaults.standard.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(profileID)")
            }
            ContinueWatchingStore.setActiveProfile(previousContinueWatchingProfileID)
            if let previousSettingsProfileID {
                ProfileSettings.setActiveProfile(previousSettingsProfileID, isPrimary: previousSettingsProfileIsPrimary)
            } else {
                ProfileSettings.clearActiveProfile()
            }
        }
        try await super.tearDown()
    }

    @MainActor
    func testOldProfileResultsCannotMergeNewProfileCheckpointsOrPublishSnapshot() {
        let context = capture()
        activate(profileB)
        seedCheckpoint()

        let result = TraktProgressService.finalizeContinueWatchingFetch(
            [remoteConfirmation(), item(meta: remoteMeta)], context: context
        )

        XCTAssertNil(result)
        XCTAssertEqual(current(checkpointMeta)?.position, 300)
        XCTAssertNil(current(remoteMeta))
    }

    @MainActor
    func testSettingsProfileSwitchAloneRejectsResultsBeforeCheckpointReconciliation() {
        let context = capture()
        seedCheckpoint()
        ProfileSettings.setActiveProfile(profileB, isPrimary: false)

        XCTAssertNil(TraktProgressService.finalizeContinueWatchingFetch(
            [remoteConfirmation(), item(meta: remoteMeta)], context: context
        ))
        XCTAssertEqual(current(checkpointMeta)?.position, 300)
        XCTAssertNil(current(remoteMeta))
    }

    @MainActor
    func testSourceSwitchRejectsDisplayedResultsBeforeCheckpointReconciliation() {
        let context = capture()
        seedCheckpoint()
        ProfileSettings.current.set(TraktWatchProgressSource.nuvioSync.rawValue,
                                    forKey: SettingsKey.traktWatchProgressSource)

        XCTAssertNil(TraktProgressService.finalizeContinueWatchingFetch(
            [remoteConfirmation(), item(meta: remoteMeta)], context: context
        ))
        XCTAssertEqual(current(checkpointMeta)?.position, 300)
        XCTAssertNil(current(remoteMeta))
    }

    @MainActor
    func testCurrentProfileResultsStillMergeAndPublish() {
        seedCheckpoint()
        let remote = item(meta: remoteMeta)
        let result = TraktProgressService.finalizeContinueWatchingFetch([remote], context: capture())

        XCTAssertEqual(Set(result?.map { $0.meta.id } ?? []), Set([checkpointMeta.id, remoteMeta.id]))
        XCTAssertEqual(current(checkpointMeta)?.position, 300)
        XCTAssertEqual(current(remoteMeta)?.position, remote.position)
    }

    @MainActor
    func testReadOnlyOverrideReturnsProviderItemsWithoutMergingOrPublishing() {
        seedCheckpoint()
        ProfileSettings.current.set(TraktWatchProgressSource.nuvioSync.rawValue,
                                    forKey: SettingsKey.traktWatchProgressSource)
        let remote = item(meta: remoteMeta)
        let result = TraktProgressService.finalizeContinueWatchingFetch(
            [remote], context: capture(updateDisplayedSnapshot: false)
        )

        XCTAssertEqual(result?.map { $0.meta.id }, [remoteMeta.id])
        XCTAssertEqual(current(checkpointMeta)?.position, 300)
        XCTAssertNil(current(remoteMeta))
    }

    @MainActor
    func testCancelledResultCannotReconcileOrPublish() async {
        seedCheckpoint()
        let context = capture()
        let items = [remoteConfirmation(), item(meta: remoteMeta)]
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return TraktProgressService.finalizeContinueWatchingFetch(items, context: context)
        }
        let result = await task.value

        XCTAssertNil(result)
        XCTAssertEqual(current(checkpointMeta)?.position, 300)
        XCTAssertNil(current(remoteMeta))
    }

    @MainActor
    private func capture(updateDisplayedSnapshot: Bool = true) -> TraktProgressService.ContinueWatchingFetchContext {
        TraktProgressService.ContinueWatchingFetchContext(source: .trakt,
                                                       updateDisplayedSnapshot: updateDisplayedSnapshot)
    }

    private var checkpointMeta: NuvioMeta { NuvioMeta(id: "cw-checkpoint-\(profileA)", name: "Local", type: "movie") }
    private var remoteMeta: NuvioMeta { NuvioMeta(id: "cw-remote-\(profileA)", name: "Remote", type: "movie") }

    private func activate(_ profileID: String) {
        ProfileSettings.setActiveProfile(profileID, isPrimary: false)
        ContinueWatchingStore.setActiveProfile(profileID)
        ProfileSettings.current.set(TraktWatchProgressSource.trakt.rawValue,
                                    forKey: SettingsKey.traktWatchProgressSource)
    }

    @MainActor
    private func seedCheckpoint() {
        TraktProgressService.recordLocalPlayback(meta: checkpointMeta, position: 300, duration: 1000,
                                                season: nil, episode: nil, source: .trakt, notify: false)
    }

    private func item(meta: NuvioMeta, position: Double = 100, date: Date = Date()) -> ContinueWatchingItem {
        ContinueWatchingItem(meta: meta, streamUrl: "", position: position, duration: 1000,
                             lastWatchedAt: date, season: nil, episode: nil)
    }

    private func remoteConfirmation() -> ContinueWatchingItem {
        // If stale reconciliation runs, this newer/further row removes the
        // current profile's local checkpoint as server-confirmed progress.
        item(meta: checkpointMeta, position: 800, date: Date().addingTimeInterval(60))
    }

    @MainActor
    private func current(_ meta: NuvioMeta) -> ContinueWatchingItem? {
        TraktProgressService.currentContinueWatchingItem(for: meta, source: .trakt)
    }
}
