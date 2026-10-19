import Foundation

enum WatchPartyLaunchError: Error { case unsupportedMedia, differentMedia }

/// Matches canonical title/episode identity. Each participant still selects their own stream;
/// source URLs and providers are not part of the room key. No inference from display names or
/// an arbitrary episode of the same series.
enum WatchPartyLaunchPolicy {
    static func validate(_ media: WatchPartyMedia) throws {
        guard !media.metaID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              media.metaID.count <= 512, !media.metaID.contains("|"),
              media.metaID.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw WatchPartyLaunchError.unsupportedMedia
        }
        switch media.metaType.lowercased() {
        case "movie":
            guard media.season == nil, media.episode == nil else { throw WatchPartyLaunchError.unsupportedMedia }
        case "series":
            guard let season = media.season, season >= 0, let episode = media.episode, episode > 0 else {
                throw WatchPartyLaunchError.unsupportedMedia
            }
        default: throw WatchPartyLaunchError.unsupportedMedia
        }
    }

    /// Room creation needs a canonical title/episode identity, not a stream URL.
    /// A series must select an explicit episode before contacting the server.
    static func mediaForDetails(_ meta: NuvioMeta, episode: NuvioVideo?) throws -> WatchPartyMedia {
        let series = meta.isSeries
        guard !series || episode != nil, series || episode == nil else {
            throw WatchPartyLaunchError.unsupportedMedia
        }
        let media = WatchPartyMedia(
            type: series ? "series" : "movie",
            metaID: meta.streamId,
            metaType: series ? "series" : "movie",
            videoID: episode?.id,
            season: episode?.season,
            episode: episode?.episode,
            title: meta.name,
            episodeTitle: episode?.title
        )
        try validate(media)
        return media
    }

    static func validateSelection(_ selection: WatchPartyMedia, room: WatchPartyMedia) throws {
        try validate(selection)
        try validate(room)
        guard selection.key == room.key else { throw WatchPartyLaunchError.differentMedia }
    }
}
