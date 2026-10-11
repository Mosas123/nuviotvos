import XCTest
@testable import NuvioTV

private final class PrimaryPlaybackCatalogRepository: CatalogRepository {
    private let metadata: NuvioMeta
    private let failsMetadataRequest: Bool
    private var cachedMetadataByID: [String: NuvioMeta] = [:]

    init(metadata: NuvioMeta, failsMetadataRequest: Bool = false) {
        self.metadata = metadata
        self.failsMetadataRequest = failsMetadataRequest
    }

    func getHomeCatalogs() async throws -> [NuvioCatalog] { [] }

    func getMetadata(id: String, type: String) async throws -> NuvioMeta {
        if failsMetadataRequest { throw TestFailure.metadataUnavailable }
        return metadata
    }

    func getStreams(id: String, type: String) async throws -> [NuvioStream] { [] }

    func search(query: String) async throws -> [NuvioMeta] { [] }

    func browseCatalog(
        contentType: String,
        catalogId: String,
        page: Int,
        genre: String?,
        year: Int?,
        sort: String?
    ) async throws -> CatalogPage {
        CatalogPage(items: [], hasMore: false, page: page)
    }

    func browseCatalog(
        contentType: String,
        catalogId: String,
        skip: Int,
        genre: String?
    ) async throws -> CatalogPage {
        CatalogPage(items: [], hasMore: false, page: 0, nextSkip: skip)
    }

    func browseCatalog(
        addonId: String?,
        contentType: String,
        catalogId: String,
        skip: Int,
        genre: String?
    ) async throws -> CatalogPage {
        CatalogPage(items: [], hasMore: false, page: 0, nextSkip: skip)
    }

    func getGenres(contentType: String) async throws -> [String] { [] }

    func getCollectionFolderItems(
        sources: [NuvioCollectionCatalogSource],
        limit: Int
    ) async -> [NuvioMeta] {
        []
    }

    func cacheCatalogMetadata(_ meta: NuvioMeta) {
        cachedMetadataByID[meta.id] = meta
    }

    func cachedMetadata(for id: String) -> NuvioMeta? {
        cachedMetadataByID[id]
    }
}

private enum TestFailure: Error {
    case metadataUnavailable
}

@MainActor
final class DetailsPrimaryMetadataReadinessTests: XCTestCase {
    func testSuccessfulMetadataLoadMarksReadiness() async {
        let meta = NuvioMeta(id: "movie", name: "Movie", type: "movie")
        let repository = PrimaryPlaybackCatalogRepository(metadata: meta)
        let viewModel = DetailsViewModel(
            repository: repository,
            streamDiscoveryMode: .repository,
            deferredPreparationDelay: { throw CancellationError() },
            enrichmentStarter: { _, _ in }
        )

        await viewModel.loadDetails(id: meta.id, type: meta.type).value

        XCTAssertTrue(viewModel.didLoadMetadataSuccessfully)
        XCTAssertNil(viewModel.metadataLoadError)
        viewModel.cancelAllTasks()
    }

    func testCachedSeriesWithoutEpisodesRemainsVisibleWhenMetadataRefreshFails() async {
        let cachedMeta = NuvioMeta(id: "cached-series", name: "Cached Series", type: "series")
        let repository = PrimaryPlaybackCatalogRepository(metadata: cachedMeta, failsMetadataRequest: true)
        repository.cacheCatalogMetadata(cachedMeta)
        let viewModel = DetailsViewModel(
            repository: repository,
            streamDiscoveryMode: .repository,
            deferredPreparationDelay: { throw CancellationError() },
            enrichmentStarter: { _, _ in }
        )

        await viewModel.loadDetails(id: cachedMeta.id, type: cachedMeta.type).value

        XCTAssertEqual(viewModel.uiState.meta?.id, cachedMeta.id)
        XCTAssertNil(viewModel.uiState.meta?.videos)
        XCTAssertFalse(viewModel.uiState.isLoading)
        XCTAssertNil(viewModel.uiState.error)
        XCTAssertFalse(viewModel.didLoadMetadataSuccessfully)
        XCTAssertNotNil(viewModel.metadataLoadError)
        viewModel.cancelAllTasks()
    }
}

final class DetailsPrimaryPlayTargetTests: XCTestCase {
    func testMovieTargetUsesPlayAndResumeLabels() {
        let movie = NuvioMeta(id: "movie", name: "Movie", type: "movie")
        let playTarget = TvDetailsPlayTargetBuilder.makePlayTarget(
            episodes: [],
            continueItem: nil,
            watchedKeys: []
        )
        let resumeTarget = TvDetailsPlayTargetBuilder.makePlayTarget(
            episodes: [],
            continueItem: continueItem(for: movie),
            watchedKeys: []
        )

        XCTAssertNil(playTarget.episode)
        XCTAssertEqual(playTarget.label, L10n.string("action_play", fallback: "Play"))
        XCTAssertTrue(playTarget.isPlayable)
        XCTAssertNil(resumeTarget.episode)
        XCTAssertEqual(resumeTarget.label, L10n.string("action_resume", fallback: "Resume"))
        XCTAssertTrue(resumeTarget.isPlayable)
    }

    func testSeriesStartsAtFirstRegularEpisodeAfterOrderingSpecialsLast() {
        let episodes = [
            episode("special", season: 0, number: 1),
            episode("s2e1", season: 2, number: 1),
            episode("s1e2", season: 1, number: 2),
            episode("s1e1", season: 1, number: 1)
        ]

        let ordered = TvDetailsPlayTargetBuilder.orderedEpisodes(episodes)
        let target = TvDetailsPlayTargetBuilder.makePlayTarget(
            episodes: ordered,
            continueItem: nil,
            watchedKeys: []
        )

        XCTAssertEqual(ordered.map(\.id), ["s1e1", "s1e2", "s2e1", "special"])
        XCTAssertEqual(target.episode?.id, "s1e1")
        XCTAssertEqual(target.label, "\(L10n.string("action_play", fallback: "Play")) S1 E1")
        XCTAssertTrue(target.isPlayable)
    }

    func testContinueWatchingResumesTheRecordedEpisode() {
        let series = seriesMeta()
        let episodes = TvDetailsPlayTargetBuilder.orderedEpisodes(series.videos ?? [])
        let target = TvDetailsPlayTargetBuilder.makePlayTarget(
            episodes: episodes,
            continueItem: continueItem(for: series, season: 1, episode: 2),
            watchedKeys: []
        )

        XCTAssertEqual(target.episode?.id, "series:1:2")
        XCTAssertEqual(target.label, "\(L10n.string("action_resume", fallback: "Resume")) S1 E2")
        XCTAssertTrue(target.isPlayable)
    }

    func testWatchedFurthestEpisodeSelectsNextEpisode() {
        let series = seriesMeta()
        let episodes = TvDetailsPlayTargetBuilder.orderedEpisodes(series.videos ?? [])
        let target = TvDetailsPlayTargetBuilder.makePlayTarget(
            episodes: episodes,
            continueItem: nil,
            watchedKeys: ["1:1", "2:1"]
        )

        XCTAssertEqual(target.episode?.id, "series:2:2")
        XCTAssertEqual(target.label, "\(L10n.string("details_next", fallback: "Next")) S2 E2")
        XCTAssertTrue(target.isPlayable)
    }

    func testUnairedNextEpisodeIsUpcomingAndNotPlayable() {
        let episodes = [
            episode("s1e1", season: 1, number: 1, released: "2020-01-01"),
            episode("s1e2", season: 1, number: 2, released: "2999-01-01")
        ]
        let target = TvDetailsPlayTargetBuilder.makePlayTarget(
            episodes: episodes,
            continueItem: nil,
            watchedKeys: ["1:1"]
        )

        XCTAssertEqual(target.episode?.id, "s1e2")
        XCTAssertEqual(target.label, "\(L10n.string("details_upcoming", fallback: "Upcoming")) S1 E2")
        XCTAssertFalse(target.isPlayable)
    }

    private func continueItem(
        for meta: NuvioMeta,
        season: Int? = nil,
        episode: Int? = nil
    ) -> ContinueWatchingItem {
        ContinueWatchingItem(
            meta: meta,
            streamUrl: "https://example.com/video.mkv",
            position: 60,
            duration: 600,
            lastWatchedAt: Date(timeIntervalSince1970: 1),
            season: season,
            episode: episode
        )
    }

    private func seriesMeta() -> NuvioMeta {
        NuvioMeta(
            id: "series",
            name: "Series",
            type: "series",
            videos: [
                episode("series:2:2", season: 2, number: 2, released: "2020-01-01"),
                episode("series:1:1", season: 1, number: 1, released: "2020-01-01"),
                episode("series:2:1", season: 2, number: 1, released: "2020-01-01"),
                episode("series:1:2", season: 1, number: 2, released: "2020-01-01")
            ]
        )
    }

    private func episode(
        _ id: String,
        season: Int,
        number: Int,
        released: String? = nil
    ) -> NuvioVideo {
        NuvioVideo(
            id: id,
            title: id,
            season: season,
            episode: number,
            released: released
        )
    }
}
