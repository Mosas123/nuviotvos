import Foundation
import XCTest
@testable import NuvioTV

final class PlaybackDiagnosticTimelineTests: XCTestCase {
    private func session() -> PlaybackDiagnosticTimeline.Session {
        .init(id: UUID(), startedAt: Date(timeIntervalSince1970: 100),
              appVersion: "3.4.4", build: "75", osVersion: "tvOS", events: [])
    }

    private func snapshot(_ store: PlaybackDiagnosticTimelineStore) async -> PlaybackDiagnosticTimelineStore.Snapshot {
        await withCheckedContinuation { continuation in
            store.snapshot { continuation.resume(returning: $0) }
        }
    }

    func testRetentionKeepsNewestEventsAndSessions() {
        var timeline = PlaybackDiagnosticTimeline()
        let first = session()
        for index in 0..<100 {
            timeline.append(.init(timestamp: Date(timeIntervalSince1970: Double(index)),
                                  name: .backPressed, engine: .aether), session: first)
        }
        XCTAssertEqual(timeline.sessions[0].events.count, 80)
        XCTAssertEqual(timeline.sessions[0].droppedEvents, 20)
        XCTAssertEqual(timeline.sessions[0].events.first?.timestamp, Date(timeIntervalSince1970: 20))
        for _ in 0..<7 {
            timeline.append(.init(timestamp: Date(), name: .playbackStarted, engine: .mpv), session: session())
        }
        XCTAssertEqual(timeline.sessions.count, 6)
        XCTAssertFalse(timeline.sessions.contains { $0.id == first.id })
    }

    func testRoundTripAndAllowlistedEventFields() throws {
        var timeline = PlaybackDiagnosticTimeline()
        timeline.append(.init(timestamp: Date(), name: .subtitleSelectionRequested, engine: .aether), session: session())
        let data = try XCTUnwrap(timeline.encoded())
        XCTAssertEqual(PlaybackDiagnosticTimeline.decode(data), timeline)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sessions = try XCTUnwrap(root["sessions"] as? [[String: Any]])
        let events = try XCTUnwrap(sessions[0]["events"] as? [[String: Any]])
        XCTAssertEqual(Set(events[0].keys), Set(["timestamp", "name", "engine"]))
        XCTAssertLessThanOrEqual(data.count, PlaybackDiagnosticTimeline.maximumBytes)
    }

    func testRejectsUnsupportedSchemaOversizedAndCorruptReports() throws {
        var timeline = PlaybackDiagnosticTimeline()
        timeline.schemaVersion = 2
        XCTAssertNil(PlaybackDiagnosticTimeline.decode(try XCTUnwrap(timeline.encoded())))
        XCTAssertNil(PlaybackDiagnosticTimeline.decode(Data(repeating: 32, count: 128 * 1024 + 1)))
        XCTAssertNil(PlaybackDiagnosticTimeline.decode(Data("not-json".utf8)))
    }

    func testPersistenceAndDeletionAcrossStoreInstances() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PlaybackDiagnosticTimelineStore(directory: directory)
        let context = session()
        store.append(.init(timestamp: Date(), name: .audioSelectionRequested, engine: .aether), session: context)
        let saved = await snapshot(store)
        XCTAssertFalse(saved.writeFailed)
        let restored = await snapshot(PlaybackDiagnosticTimelineStore(directory: directory))
        XCTAssertEqual(restored.timeline, saved.timeline)

        // Deleting must also discard events not yet flushed to disk.
        store.append(.init(timestamp: Date(), name: .backPressed, engine: .aether), session: context)
        let deleted = await withCheckedContinuation { continuation in
            store.removeAll { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(deleted)
        let empty = await snapshot(store)
        let emptyAfterRelaunch = await snapshot(PlaybackDiagnosticTimelineStore(directory: directory))
        XCTAssertTrue(empty.timeline.sessions.isEmpty)
        XCTAssertTrue(emptyAfterRelaunch.timeline.sessions.isEmpty)
    }

    func testCorruptSavedFileDoesNotPreventFreshRecording() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("incomplete report".utf8).write(to: directory.appendingPathComponent("timeline.json"))
        let store = PlaybackDiagnosticTimelineStore(directory: directory)
        store.append(.init(timestamp: Date(), name: .recordingEnabled, engine: nil), session: session())
        let restored = await snapshot(store)
        XCTAssertFalse(restored.writeFailed)
        XCTAssertEqual(restored.timeline.sessions.first?.events.first?.name, .recordingEnabled)
    }

    func testExportAcceptsOnlyExactTokenizedBodylessGet() {
        let path = "/private-token/report.json"
        func accepts(_ request: String) -> Bool {
            PlaybackDiagnosticExportServer.accepts(Data(request.utf8), path: path)
        }
        XCTAssertTrue(accepts("GET \(path) HTTP/1.1\r\nHost: appletv\r\n\r\n"))
        XCTAssertTrue(accepts("GET \(path) HTTP/1.0\r\n\r\n"))
        XCTAssertFalse(accepts("POST \(path) HTTP/1.1\r\n\r\n"))
        XCTAssertFalse(accepts("GET /report.json HTTP/1.1\r\n\r\n"))
        XCTAssertFalse(accepts("GET /../timeline.json HTTP/1.1\r\n\r\n"))
        XCTAssertFalse(accepts("GET \(path) HTTP/1.1\r\nContent-Length: 0\r\n\r\n"))
        XCTAssertFalse(accepts("GET \(path) HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"))
        XCTAssertFalse(accepts("GET \(path) HTTP/1.1\r\n\r\nbody"))
        XCTAssertFalse(accepts("GET \(path) HTTP/1.1\r\n"))
        XCTAssertFalse(accepts("GET \(path) HTTP/1.1\r\nX: " + String(repeating: "a", count: 8192) + "\r\n\r\n"))
    }
}
