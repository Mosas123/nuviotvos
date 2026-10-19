import Foundation

enum WatchPartyLaunchError: Error { case unsupportedMedia, differentMedia }

/// MVP supports canonical movie/series IDs and an explicitly chosen own copy of the same edition.
/// No inference from display names, received URLs or an arbitrary episode of the same series.
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

    static func validateSelection(_ selection: WatchPartyMedia, room: WatchPartyMedia) throws {
        try validate(selection)
        try validate(room)
        guard selection.key == room.key else { throw WatchPartyLaunchError.differentMedia }
    }
}
