import Foundation
import XCTest
@testable import NuvioTV

private final class FailingMetadataRepository: MockCatalogRepository {
    override func getMetadata(id: String, type: String) async throws -> NuvioMeta {
        throw NSError(domain: "MetadataLookupTest", code: 42)
    }
}

private final class CancelledMetadataRepository: MockCatalogRepository {
    override func getMetadata(id: String, type: String) async throws -> NuvioMeta {
        throw CancellationError()
    }
}

private final class URLCancelledMetadataRepository: MockCatalogRepository {
    override func getMetadata(id: String, type: String) async throws -> NuvioMeta {
        throw URLError(.cancelled)
    }
}

private final class SuccessfulMetadataRepository: MockCatalogRepository {
    override func getMetadata(id: String, type: String) async throws -> NuvioMeta {
        NuvioMeta(id: id, name: "Recovered metadata", type: type)
    }
}

@MainActor
final class WatchProgressFixtureCleanupTests: XCTestCase {
    func testFixtureClassifierMatchesOnlyKnownIDsAndCanonicalDismissUUIDs() {
        let exactIDs = [
            "tt-playback-completion",
            "tt-resume-rewind",
            "series-completion",
            "series-inferred"
        ]
        for id in exactIDs {
            XCTAssertTrue(WatchProgressLedger.isKnownRegressionFixture(contentId: id), id)
        }

        let dismissID = "tt-dismiss-race-\(UUID().uuidString)"
        XCTAssertTrue(WatchProgressLedger.isKnownRegressionFixture(contentId: dismissID))
        XCTAssertFalse(WatchProgressLedger.isKnownRegressionFixture(contentId: "tt-playback-completion-extra"))
        XCTAssertFalse(WatchProgressLedger.isKnownRegressionFixture(contentId: "tt-dismiss-race-not-a-uuid"))
        XCTAssertFalse(WatchProgressLedger.isKnownRegressionFixture(contentId: "tt-dismiss-race-\(UUID().uuidString)-extra"))
        XCTAssertFalse(WatchProgressLedger.isKnownRegressionFixture(contentId: "tt1234567"))
    }

    func testBuilderPlanExcludesKnownFixturesWithoutDroppingRealProgress() {
        let fixture = makeProgress(contentId: "series-completion", type: "series")
        let dynamicFixture = makeProgress(contentId: "tt-dismiss-race-\(UUID().uuidString)", type: "series")
        let real = makeProgress(contentId: "tt1234567", type: "movie")

        let plan = ContinueWatchingBuilder.planEntries(
            candidates: [fixture, dynamicFixture, real],
            seeds: []
        )

        XCTAssertEqual(plan.map(\.record.contentId), [real.contentId])
    }

    func testWatchedHistorySeedsExcludeOnlyExactLegacyRewatchFixture() {
        let profileId = "watched-seed-fixture-\(UUID().uuidString)"
        let previousProfileId = WatchedStore.activeProfileId
        WatchedStore.setActiveProfile(profileId)
        WatchedStore.eraseProfile(profileId)
        WatchProgressLedger.eraseProfile(profileId)
        defer {
            WatchedStore.eraseProfile(profileId)
            WatchProgressLedger.eraseProfile(profileId)
            WatchedStore.setActiveProfile(previousProfileId)
        }

        func makeSeriesMeta(id: String, name: String, tmdbId: Int, year: Int) -> NuvioMeta {
            NuvioMeta(
                id: id, name: name, imdbId: "tt8888889", tmdbId: tmdbId,
                type: "series", year: year
            )
        }

        let exactMeta = makeSeriesMeta(id: "tt8888889", name: "Rewatch Series", tmdbId: 301, year: 2024)
        let sameIMDbDifferentTitle = makeSeriesMeta(
            id: "series-same-imdb-title", name: "Rewatch Series Remastered", tmdbId: 301, year: 2024
        )
        let sameIMDbDifferentTMDB = makeSeriesMeta(
            id: "series-same-imdb-tmdb", name: "Rewatch Series", tmdbId: 302, year: 2024
        )
        let sameIMDbDifferentYear = makeSeriesMeta(
            id: "series-same-imdb-year", name: "Rewatch Series", tmdbId: 301, year: 2025
        )
        let watchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let watchedItems = [
            WatchedStoreItem(meta: exactMeta, watchedAt: watchedAt, season: 1, episode: 1),
            WatchedStoreItem(meta: sameIMDbDifferentTitle, watchedAt: watchedAt.addingTimeInterval(-1), season: 1, episode: 1),
            WatchedStoreItem(meta: sameIMDbDifferentTMDB, watchedAt: watchedAt.addingTimeInterval(-2), season: 1, episode: 1),
            WatchedStoreItem(meta: sameIMDbDifferentYear, watchedAt: watchedAt.addingTimeInterval(-3), season: 1, episode: 1),
            WatchedStoreItem(meta: exactMeta, watchedAt: watchedAt.addingTimeInterval(-4), season: 1, episode: 2)
        ]
        WatchedStore.replaceAll(watchedItems, profileId: profileId)
        let ledgerRecord = makeProgress(contentId: exactMeta.id, type: "series")
        XCTAssertTrue(WatchProgressLedger.upsert(ledgerRecord, profileId: profileId))

        let rowsBefore = WatchedStore.items(profileId: profileId)
        let tombstonesBefore = WatchedStore.tombstones(profileId: profileId)
        let ledgerBefore = WatchProgressLedger.records(profileId: profileId)
        let seeds = ContinueWatchingBuilder.watchedHistorySeeds()
        let seedKeys = Set(seeds.map { "\($0.contentId)|\($0.season ?? 0)|\($0.episode ?? 0)" })

        XCTAssertFalse(seedKeys.contains("tt8888889|1|1"), "Only the exact legacy episode row is excluded")
        XCTAssertTrue(seedKeys.contains("tt8888889|1|2"), "Another episode of the same series remains eligible")
        XCTAssertTrue(seedKeys.contains("series-same-imdb-title|1|1"))
        XCTAssertTrue(seedKeys.contains("series-same-imdb-tmdb|1|1"))
        XCTAssertTrue(seedKeys.contains("series-same-imdb-year|1|1"))
        XCTAssertEqual(WatchedStore.items(profileId: profileId), rowsBefore, "Seed planning leaves watched history untouched")
        XCTAssertEqual(WatchedStore.tombstones(profileId: profileId), tombstonesBefore)
        XCTAssertEqual(WatchProgressLedger.records(profileId: profileId), ledgerBefore, "Seed planning leaves ledger rows untouched")
    }

    func testFixtureCleanupBacksUpRetriesPerProfileAndPreservesRealRecords() async {
        let profileId = "fixture-cleanup-\(UUID().uuidString)"
        let otherProfileId = "fixture-cleanup-other-\(UUID().uuidString)"
        defer {
            WatchProgressLedger.eraseProfile(profileId)
            WatchProgressLedger.eraseProfile(otherProfileId)
        }

        let fixture = makeProgress(contentId: "tt-playback-completion", type: "movie")
        let localOnlyFixture = makeProgress(contentId: "series-inferred", type: "series")
        let real = makeProgress(contentId: "tt1234567", type: "movie")
        let remoteSnapshot = [fixture, real]
        XCTAssertTrue(WatchProgressLedger.upsert(fixture, profileId: profileId))
        XCTAssertTrue(WatchProgressLedger.upsert(localOnlyFixture, profileId: profileId))
        XCTAssertTrue(WatchProgressLedger.upsert(real, profileId: profileId))

        var deleteAttempts: [([String], String?)] = []
        let afterFailure = await NuvioSyncManager.removeKnownRegressionFixturesFromSnapshot(
            remoteSnapshot,
            profileId: profileId
        ) { keys, selectedProfile in
            deleteAttempts.append((keys, selectedProfile))
            return false
        }

        XCTAssertEqual(afterFailure?.map(\.contentId) ?? [], [real.contentId])
        XCTAssertEqual(deleteAttempts.count, 1)
        XCTAssertEqual(deleteAttempts[0].0, [fixture.progressKey])
        XCTAssertEqual(deleteAttempts[0].1, profileId)
        XCTAssertEqual(WatchProgressLedger.pendingKnownRegressionFixtureCleanupKeys(profileId: profileId), [fixture.progressKey])
        XCTAssertEqual(
            Set(WatchProgressLedger.knownRegressionFixtureCleanupRecords(profileId: profileId).map(\.contentId)),
            Set([fixture.contentId, localOnlyFixture.contentId]),
            "Archive both remote and local fixture rows before removing local progress"
        )
        XCTAssertEqual(WatchProgressLedger.records(profileId: profileId), [real])
        XCTAssertTrue(WatchProgressLedger.pendingKnownRegressionFixtureCleanupKeys(profileId: otherProfileId).isEmpty)

        XCTAssertTrue(WatchProgressLedger.backupKnownRegressionFixtures([makeProgress(contentId: "tt-resume-rewind", type: "movie")], profileId: otherProfileId))
        XCTAssertEqual(WatchProgressLedger.pendingKnownRegressionFixtureCleanupKeys(profileId: otherProfileId), ["tt-resume-rewind"])

        let afterRetry = await NuvioSyncManager.removeKnownRegressionFixturesFromSnapshot(
            remoteSnapshot,
            profileId: profileId
        ) { keys, selectedProfile in
            deleteAttempts.append((keys, selectedProfile))
            return true
        }

        XCTAssertEqual(afterRetry?.map(\.contentId) ?? [], [real.contentId])
        XCTAssertEqual(deleteAttempts.count, 2)
        XCTAssertEqual(deleteAttempts[1].0, [fixture.progressKey])
        XCTAssertEqual(deleteAttempts[1].1, profileId)
        XCTAssertTrue(WatchProgressLedger.pendingKnownRegressionFixtureCleanupKeys(profileId: profileId).isEmpty)
        XCTAssertEqual(
            Set(WatchProgressLedger.knownRegressionFixtureCleanupRecords(profileId: profileId).map(\.contentId)),
            Set([fixture.contentId, localOnlyFixture.contentId]),
            "Successful delete keeps the fixture backup archive for inspection"
        )
        XCTAssertEqual(WatchProgressLedger.records(profileId: profileId), [real], "Fixture cleanup must preserve real progress")
        XCTAssertEqual(WatchProgressLedger.pendingKnownRegressionFixtureCleanupKeys(profileId: otherProfileId), ["tt-resume-rewind"])
    }

    func testFixtureBackupFailureDoesNotDeleteOrFilterRemoteRows() async {
        let profileId = "fixture-cleanup-backup-failure-\(UUID().uuidString)"
        defer { WatchProgressLedger.eraseProfile(profileId) }
        XCTAssertTrue(LargePayloadStore.write(
            Data("invalid archive".utf8),
            key: WatchProgressLedger.fixtureCleanupArchiveStorageKey(profileId: profileId),
            directory: WatchProgressLedger.fixtureCleanupArchiveDirectoryName
        ))

        let fixture = makeProgress(contentId: "series-inferred", type: "series")
        let real = makeProgress(contentId: "tt1234567", type: "movie")
        XCTAssertTrue(WatchProgressLedger.upsert(fixture, profileId: profileId))
        var deleteCalled = false

        let result = await NuvioSyncManager.removeKnownRegressionFixturesFromSnapshot(
            [fixture, real],
            profileId: profileId
        ) { _, _ in
            deleteCalled = true
            return true
        }

        XCTAssertFalse(deleteCalled)
        XCTAssertNil(result, "Reconcile must be deferred when the fixture backup cannot be verified")
        XCTAssertTrue(WatchProgressLedger.pendingKnownRegressionFixtureCleanupKeys(profileId: profileId).isEmpty)
        XCTAssertEqual(WatchProgressLedger.records(profileId: profileId), [fixture], "Backup failure leaves local progress intact")
    }

    func testStalePullKeepsRetryMarkerAfterCapturedAccountDelete() async {
        let profileId = "fixture-cleanup-stale-pull-\(UUID().uuidString)"
        defer { WatchProgressLedger.eraseProfile(profileId) }
        let fixture = makeProgress(contentId: "tt-resume-rewind", type: "movie")
        var currentAccountId = "account-a"
        var deletionAccountId: String?

        let result = await NuvioSyncManager.removeKnownRegressionFixturesFromSnapshot(
            [fixture],
            profileId: profileId,
            isCurrentPull: { currentAccountId == "account-a" }
        ) { keys, selectedProfile in
            deletionAccountId = "account-a" // The pull's captured session owns the request.
            XCTAssertEqual(keys, [fixture.progressKey])
            XCTAssertEqual(selectedProfile, profileId)
            currentAccountId = "account-b" // Simulate switching accounts while the request is in flight.
            return true
        }

        XCTAssertEqual(deletionAccountId, "account-a")
        XCTAssertTrue(result?.isEmpty == true)
        XCTAssertEqual(
            WatchProgressLedger.pendingKnownRegressionFixtureCleanupKeys(profileId: profileId),
            [fixture.progressKey],
            "A stale pull must retain the retry marker even if its captured account delete succeeded"
        )
    }

    func testMetadataFailureAndCancellationAreReportedWithoutRemovingLedgerRows() async {
        let profileId = "metadata-miss-\(UUID().uuidString)"
        defer { WatchProgressLedger.eraseProfile(profileId) }
        let record = makeProgress(contentId: "tt-metadata-miss", type: "movie")
        XCTAssertTrue(WatchProgressLedger.upsert(record, profileId: profileId))

        let failure = await ContinueWatchingBuilder.lookupMetadata(
            id: record.contentId,
            type: record.contentType,
            needsVideos: false,
            repository: FailingMetadataRepository()
        )
        XCTAssertNil(failure.meta)
        XCTAssertEqual(failure.failureReason, "error domain=MetadataLookupTest code=42")
        XCTAssertFalse(failure.wasCancelled)
        XCTAssertEqual(WatchProgressLedger.record(forKey: record.progressKey, profileId: profileId), record)

        let retry = await ContinueWatchingBuilder.lookupMetadata(
            id: record.contentId,
            type: record.contentType,
            needsVideos: false,
            repository: SuccessfulMetadataRepository()
        )
        XCTAssertEqual(retry.meta?.name, "Recovered metadata", "A failed lookup must not be permanently cached as missing")

        let cancelled = await ContinueWatchingBuilder.lookupMetadata(
            id: record.contentId,
            type: record.contentType,
            needsVideos: false,
            repository: CancelledMetadataRepository()
        )
        XCTAssertNil(cancelled.meta)
        XCTAssertEqual(cancelled.failureReason, "cancelled during lookup")
        XCTAssertTrue(cancelled.wasCancelled)
        XCTAssertEqual(WatchProgressLedger.record(forKey: record.progressKey, profileId: profileId), record)

        let networkCancelled = await ContinueWatchingBuilder.lookupMetadata(
            id: record.contentId,
            type: record.contentType,
            needsVideos: false,
            repository: URLCancelledMetadataRepository()
        )
        XCTAssertEqual(networkCancelled.failureReason, "error domain=NSURLErrorDomain code=\(URLError.cancelled.rawValue)")
        XCTAssertTrue(networkCancelled.wasCancelled)
        XCTAssertEqual(WatchProgressLedger.record(forKey: record.progressKey, profileId: profileId), record)
    }

    func testDeviceRegistrationUnsupportedRequiresExactServerCapabilityMessage() {
        XCTAssertTrue(NuvioDeviceRegistrationCapability.isExplicitlyUnsupported(
            AuthError(message: "  unsupported nuvio client\n", statusCode: 400)
        ))
        XCTAssertFalse(NuvioDeviceRegistrationCapability.isExplicitlyUnsupported(
            AuthError(message: "Unsupported Nuvio client: request failed", statusCode: 404)
        ))
        XCTAssertFalse(NuvioDeviceRegistrationCapability.isExplicitlyUnsupported(
            AuthError(message: "Unauthorized", statusCode: 401)
        ))
        XCTAssertFalse(NuvioDeviceRegistrationCapability.isExplicitlyUnsupported(
            URLError(.notConnectedToInternet)
        ))
        XCTAssertNotEqual(
            NuvioDeviceRegistrationCapability.accountVersionKey(accountId: "account-a", clientVersion: "1.0"),
            NuvioDeviceRegistrationCapability.accountVersionKey(accountId: "account-b", clientVersion: "1.0")
        )
        XCTAssertNotEqual(
            NuvioDeviceRegistrationCapability.accountVersionKey(accountId: "account-a", clientVersion: "1.0"),
            NuvioDeviceRegistrationCapability.accountVersionKey(accountId: "account-a", clientVersion: "1.1")
        )
    }

    private func makeProgress(contentId: String, type: String) -> WatchProgressRecord {
        WatchProgressRecord(
            progressKey: WatchProgressLedger.progressKey(contentId: contentId, season: nil, episode: nil),
            contentId: contentId,
            contentType: type,
            videoId: WatchProgressLedger.videoId(contentId: contentId, season: nil, episode: nil),
            season: nil,
            episode: nil,
            position: 120,
            duration: 1_000,
            lastWatchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
