import XCTest
@testable import NuvioTV

@MainActor
final class CollectionHomeModelTests: XCTestCase {

    func testCollectionSidebarPreferencesProfileIsolation() {
        let profileA = "profile-a-\(UUID().uuidString)"
        let profileB = "profile-b-\(UUID().uuidString)"
        let col1 = "collection-1"
        let col2 = "collection-2"

        CollectionSidebarPreferences.setEnabled(true, collectionID: col1, profileID: profileA)
        CollectionSidebarPreferences.setEnabled(true, collectionID: col2, profileID: profileB)

        let aIDs = CollectionSidebarPreferences.collectionIDs(profileID: profileA)
        let bIDs = CollectionSidebarPreferences.collectionIDs(profileID: profileB)

        XCTAssertTrue(aIDs.contains(col1))
        XCTAssertFalse(aIDs.contains(col2))

        XCTAssertTrue(bIDs.contains(col2))
        XCTAssertFalse(bIDs.contains(col1))

        CollectionSidebarPreferences.setEnabled(false, collectionID: col1, profileID: profileA)
        XCTAssertFalse(CollectionSidebarPreferences.collectionIDs(profileID: profileA).contains(col1))
    }

    func testCollectionHomeIDKeyConsistency() {
        let id1 = CollectionHomeID(profileID: "prof1", collectionID: "col1", folderID: "fold1")
        let id2 = CollectionHomeID(profileID: "prof1", collectionID: "col1", folderID: "fold1")
        let id3 = CollectionHomeID(profileID: "prof1", collectionID: "col2", folderID: "fold1")

        XCTAssertEqual(id1, id2)
        XCTAssertEqual(id1.key, id2.key)
        XCTAssertNotEqual(id1, id3)
        XCTAssertNotEqual(id1.key, id3.key)
    }

    func testCollectionHomeModelLifecycle() {
        let profileID = "test-profile-\(UUID().uuidString)"
        let folderJSON = """
        {"id": "fold1", "title": "Folder 1"}
        """.data(using: .utf8)!
        let folder = try! JSONDecoder().decode(NuvioCollectionFolder.self, from: folderJSON)
        let destination = CollectionHomeDestination(
            id: CollectionHomeID(profileID: profileID, collectionID: "col1", folderID: "fold1"),
            collectionTitle: "Test Collection",
            folder: TVCollectionFolderItem(
                collectionId: "col1",
                folder: folder,
                sources: [],
                viewMode: .followLayout,
                showAllTab: false
            )
        )
        let repository = CinemetaCatalogRepository()
        let model = CollectionHomeModel(destination: destination, repository: repository)

        XCTAssertTrue(model.failures.isEmpty)
        XCTAssertTrue(model.retryingRows.isEmpty)
        XCTAssertNil(model.store.hero)
        XCTAssertTrue(model.store.sections.isEmpty)

        model.releaseCatalogs()
        XCTAssertTrue(model.failures.isEmpty)
        XCTAssertTrue(model.store.sections.isEmpty)
    }
}
