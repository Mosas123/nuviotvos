import Foundation

/// A deliberately small allowlist, not a dump of errors, URLs or the debug HUD.
/// Free-form source/provider/content fields can contain private credentials.
struct PlaybackIssueReport: Encodable, Sendable {
    let schemaVersion = 1
    let createdAt: Date
    let engine: String
    let category: String
    let failure: String
    let isLive: Bool
    let renderedFirstFrame: Bool
    let positionSeconds: Double?
    let durationSeconds: Double?

    init(
        message: String,
        streamURL: URL?,
        engine: PlayerEngineKind,
        isLive: Bool,
        renderedFirstFrame: Bool,
        position: Double,
        duration: Double,
        createdAt: Date = Date()
    ) {
        // Only the classifier's fixed category/badge strings are persisted.
        // Never persist its message, host or technicalDetails, which can echo input.
        let diagnostic = PlaybackErrorDiagnostic.analyze(
            errorMessage: String(message.prefix(4096)), streamURL: streamURL
        )
        self.createdAt = createdAt
        self.engine = engine.rawValue
        category = diagnostic.origin.rawValue
        failure = diagnostic.badgeText
        self.isLive = isLive
        self.renderedFirstFrame = renderedFirstFrame
        positionSeconds = position.isFinite && position >= 0 ? position : nil
        durationSeconds = duration.isFinite && duration >= 0 ? duration : nil
    }
}

enum PlaybackIssueReportStore {
    private static let queue = DispatchQueue(label: "nuvio.playback-issue-reports", qos: .utility)
    static let maximumReports = 20
    static let maximumReportBytes = 4096

    static func enqueue(_ report: PlaybackIssueReport) {
        queue.async {
            let manager = FileManager.default
            guard let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
            let directory = support.appendingPathComponent("NuvioTV", isDirectory: true)
                .appendingPathComponent("PlaybackIssueReports", isDirectory: true)
            _ = write(report, to: directory)
        }
    }

    /// Called on the serial writer queue; internal for isolated filesystem tests.
    /// Failure never changes playback state or surfaces a second player error.
    @discardableResult
    static func write(_ report: PlaybackIssueReport, to directory: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(report), data.count <= maximumReportBytes else { return false }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            // Only prune regular JSON files owned by this writer. A failed prune
            // aborts the new write rather than allowing retention to grow unbounded.
            let files = try manager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ).filter { url in
                guard url.pathExtension == "json", url.lastPathComponent.hasPrefix("playback-"),
                      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return false }
                return true
            }.sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left == right ? $0.lastPathComponent < $1.lastPathComponent : left > right
            }
            for stale in files.dropFirst(maximumReports - 1) {
                try manager.removeItem(at: stale)
            }
            let target = directory.appendingPathComponent("playback-\(UUID().uuidString).json")
            try data.write(to: target, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
