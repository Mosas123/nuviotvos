import XCTest
@testable import NuvioTV

final class LibraryMergeTests: XCTestCase {
    private func item(_ meta: NuvioMeta) -> LibraryStoreItem {
        LibraryStoreItem(meta: meta, addedAt: Date(timeIntervalSince1970: 0))
    }

    func testTitlesAlreadyInTheSelectedLibraryAreLeftOut() {
        let selected = [StremioMeta(id: "tt1375666", name: "Inception", contentType: "movie", year: 2010)]
        let trakt = [
            item(NuvioMeta(id: "tt1375666", name: "Inception", type: "movie", year: 2010)),
            item(NuvioMeta(id: "tt0816692", name: "Interstellar", type: "movie", year: 2014)),
        ]
        let merged = LibraryMerge.others([("Trakt", trakt)], excluding: selected)
        XCTAssertEqual(merged.map(\.meta.id), ["tt0816692"])
        XCTAssertEqual(merged.first?.label, "Trakt")
    }

    func testTheSameTitleFromTwoServicesShowsOnceWithTheFirstLabel() {
        let trakt = [item(NuvioMeta(id: "tt1375666", name: "Inception", imdbId: "tt1375666", type: "movie", year: 2010))]
        let simkl = [
            item(NuvioMeta(id: "tmdb:27205", name: "Inception", imdbId: "tt1375666", tmdbId: 27205, type: "movie", year: 2010)),
            item(NuvioMeta(id: "tmdb:157336", name: "Interstellar", tmdbId: 157336, type: "movie", year: 2014)),
        ]
        let mdblist = [item(NuvioMeta(id: "tmdb:27205", name: "Inception", tmdbId: 27205, type: "movie"))]
        let merged = LibraryMerge.others([("Trakt", trakt), ("Simkl", simkl), ("MDBList", mdblist)], excluding: [])
        XCTAssertEqual(merged.map(\.meta.id), ["tt1375666", "tmdb:157336"])
        XCTAssertEqual(merged.map(\.label), ["Trakt", "Simkl"])
    }

    func testDifferentTitlesWithTheSameNameStaySeparate() {
        let remakes = [
            item(NuvioMeta(id: "tt1", name: "Dune", type: "movie", year: 1984)),
            item(NuvioMeta(id: "tt2", name: "Dune", type: "movie", year: 2021)),
        ]
        XCTAssertEqual(LibraryMerge.others([("Trakt", remakes)], excluding: []).count, 2)
    }
}
