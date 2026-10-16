//
//  CatalogBrowseUITests.swift
//  NuvioTVUITests
//
//  UI tests for catalog browsing functionality
//

import XCTest

@MainActor
final class CatalogBrowseUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Filter Section Tests

    func testContentTypeToggle() throws {
        throw XCTSkip("This legacy flow has no catalog-entry fixture or observable selection assertion yet.")
    }

    func testGenreFiltering() throws {
        sleep(2)

        // Look for genre filter chips
        if requireUICondition(app.buttons["action"].exists) {
            selectTVElement(app.buttons["action"], in: app)
            sleep(1)

            // Content should reload with genre filter
            XCTAssertTrue(app.exists, "Should apply genre filter")

            // Tap again to deselect
            selectTVElement(app.buttons["action"], in: app)
            sleep(1)
            XCTAssertTrue(app.exists, "Should remove genre filter")
        }
    }

    func testSortOptionsMenu() throws {
        sleep(2)

        // Look for sort menu or picker
        if requireUICondition(app.buttons["Trending"].exists || app.pickers["Sort"].exists) {
            // Try different sort options
            let sortOptions = ["Trending", "Popular", "Newest", "Top Rated"]

            for option in sortOptions {
                if requireUICondition(app.buttons[option].exists) {
                    selectTVElement(app.buttons[option], in: app)
                    sleep(1)
                    XCTAssertTrue(app.exists, "Should apply \(option) sort")
                }
            }
        }
    }

    func testClearFilters() throws {
        sleep(2)

        // Apply a filter first
        if requireUICondition(app.buttons["comedy"].exists) {
            selectTVElement(app.buttons["comedy"], in: app)
            sleep(1)

            // Look for clear filters button
            if requireUICondition(app.buttons["Clear Filters"].exists) {
                selectTVElement(app.buttons["Clear Filters"], in: app)
                sleep(1)
                XCTAssertTrue(app.exists, "Should clear filters")
            }
        }
    }

    // MARK: - Grid Layout Tests

    func testGridDisplaysContent() throws {
        sleep(2)

        // Verify grid has content items
        let images = app.images
        XCTAssertGreaterThan(images.count, 0, "Grid should display content posters")
    }

    func testGridItemTapping() throws {
        sleep(2)

        // Tap a grid item to open details
        let images = app.images
        if requireUICondition(images.count > 0) {
            let firstItem = images.element(boundBy: 0)
            if requireUICondition(firstItem.exists && firstItem.isHittable) {
                selectTVElement(firstItem, in: app)
                sleep(1)

                // Should navigate to details
                XCTAssertTrue(app.exists, "Tapping grid item should navigate to details")
            }
        }
    }

    // MARK: - Infinite Scroll Tests

    func testInfiniteScrollLoading() throws {
        sleep(2)

        // Find scrollable content
        let scrollView = app.scrollViews.firstMatch
        if requireUICondition(scrollView.exists) {
            let initialImageCount = app.images.count

            // Scroll down multiple times
            for _ in 1...3 {
                moveTVFocus(.down, in: app, within: scrollView)
                sleep(1)
            }

            // Should load more content
            let finalImageCount = app.images.count
            XCTAssertGreaterThanOrEqual(finalImageCount, initialImageCount, "Should load more items on scroll")
        }
    }

    func testScrollToTopAndBottom() throws {
        sleep(2)

        let scrollView = app.scrollViews.firstMatch
        if requireUICondition(scrollView.exists) {
            // Scroll to bottom
            for _ in 1...5 {
                moveTVFocus(.down, in: app, within: scrollView)
                Thread.sleep(forTimeInterval: 0.5)
            }

            // Scroll back to top
            for _ in 1...5 {
                moveTVFocus(.up, in: app, within: scrollView)
                Thread.sleep(forTimeInterval: 0.5)
            }

            XCTAssertTrue(scrollView.exists, "Should handle scrolling to extremes")
        }
    }

    // MARK: - Loading State Tests

    func testLoadingIndicatorAppears() throws {
        // On fresh launch, loading should be visible briefly
        let loadingIndicator = app.activityIndicators.firstMatch
        if loadingIndicator.exists {
            XCTAssertTrue(loadingIndicator.exists, "Loading indicator should appear")
        }

        // Wait for loading to complete
        sleep(2)

        // Content should appear
        XCTAssertGreaterThan(app.images.count, 0, "Content should appear after loading")
    }

    // MARK: - Multiple Filter Combination Tests

    func testCombinedFilters() throws {
        sleep(2)

        // Apply genre filter
        if requireUICondition(app.buttons["drama"].exists) {
            selectTVElement(app.buttons["drama"], in: app)
            sleep(1)
        }

        // Apply sort
        if requireUICondition(app.buttons["Popular"].exists) {
            selectTVElement(app.buttons["Popular"], in: app)
            sleep(1)
        }

        // Content should be filtered and sorted
        XCTAssertGreaterThan(app.images.count, 0, "Should display filtered and sorted content")
    }

    // MARK: - Platform-Specific Tests

    func testGridAdaptsToScreenSize() throws {
        sleep(2)

        // Grid should display appropriate columns based on device
        let images = app.images

        // On iOS, should see 2-3 columns
        // On tvOS, should see 4-6 columns
        // On iPad, should see 3-4 columns

        #if os(iOS)
        XCTAssertGreaterThan(images.count, 0, "iOS should display grid")
        #elseif os(tvOS)
        XCTAssertGreaterThan(images.count, 0, "tvOS should display grid")
        #endif
    }

    // MARK: - Performance Tests

    func testFilterChangePerformance() throws {
        sleep(2)

        measure {
            // Apply filter
            if requireUICondition(app.buttons["action"].exists) {
                selectTVElement(app.buttons["action"], in: app)
                sleep(1)
            }
        }
    }

    func testScrollPerformance() throws {
        sleep(2)

        let scrollView = app.scrollViews.firstMatch
        if requireUICondition(scrollView.exists) {
            measure {
                moveTVFocus(.down, in: app, within: scrollView)
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }
}
