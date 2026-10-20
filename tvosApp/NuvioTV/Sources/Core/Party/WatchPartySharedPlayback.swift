import Foundation

enum WatchPartySharedPlaybackError: Error, Equatable {
    case staleSelection, unsupportedResponseHeaders, missingEpisode, differentMedia
}

struct WatchPartySharedPlaybackTarget {
    let meta: NuvioMeta
    let episode: NuvioVideo?
    let url: URL
    let stream: WatchPartyStream
}

/// Resolves catalog identity only. Never probes, logs or persists the private source URL.
enum WatchPartySharedPlaybackResolver {
    @MainActor
    static func resolve(
        stream: WatchPartyStream, room: WatchPartyMedia,
        isCurrent: () -> Bool,
        loadMetadata: (String, String) async throws -> NuvioMeta
    ) async throws -> WatchPartySharedPlaybackTarget {
        try Task.checkCancellation()
        guard isCurrent() else { throw WatchPartySharedPlaybackError.staleSelection }
        try WatchPartyLaunchPolicy.validate(room)
        try WatchPartyStreamPolicy.validate(stream)
        guard stream.mediaKey == room.key else { throw WatchPartySharedPlaybackError.differentMedia }
        // The existing player entry point supports request headers only. Do not silently drop
        // response semantics or send response headers to the origin as request headers.
        guard stream.responseHeaders.isEmpty else {
            throw WatchPartySharedPlaybackError.unsupportedResponseHeaders
        }
        let meta = try await loadMetadata(room.metaID, room.metaType)
        try Task.checkCancellation()
        guard isCurrent() else { throw WatchPartySharedPlaybackError.staleSelection }
        return try target(meta: meta, stream: stream, room: room)
    }

    static func target(meta: NuvioMeta, stream: WatchPartyStream,
                       room: WatchPartyMedia) throws -> WatchPartySharedPlaybackTarget {
        try WatchPartyLaunchPolicy.validate(room)
        try WatchPartyStreamPolicy.validate(stream)
        guard stream.responseHeaders.isEmpty else {
            throw WatchPartySharedPlaybackError.unsupportedResponseHeaders
        }
        let supportedType = meta.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "movie"
            || NuvioMeta.isSeriesType(meta.type)
        guard stream.mediaKey == room.key, supportedType else {
            throw WatchPartySharedPlaybackError.differentMedia
        }
        let episode: NuvioVideo?
        if room.metaType.lowercased() == "series" {
            let matches = (meta.videos ?? []).filter { $0.season == room.season && $0.episode == room.episode }
            guard matches.count == 1 else { throw WatchPartySharedPlaybackError.missingEpisode }
            episode = matches[0]
        } else {
            episode = nil
        }
        let selected = try WatchPartyLaunchPolicy.mediaForPlayback(meta, episode: episode, room: room)
        try WatchPartyLaunchPolicy.validateSelection(selected, room: room)
        guard let url = URL(string: stream.url) else { throw WatchPartyStreamError.invalidURL }
        return WatchPartySharedPlaybackTarget(meta: meta, episode: episode, url: url, stream: stream)
    }
}
