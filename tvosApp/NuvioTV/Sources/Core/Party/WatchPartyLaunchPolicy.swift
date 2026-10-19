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

    static func validateSelection(_ selection: WatchPartyMedia, room: WatchPartyMedia) throws {
        try validate(selection)
        try validate(room)
        guard selection.key == room.key else { throw WatchPartyLaunchError.differentMedia }
    }
}

    
/// Picks an actually available tvOS focus destination when returning to the room.
/// The room code field must not receive focus while a membership still exists.
enum WatchPartyRoomFocusPolicy {
    static func initialAction(hasRoom: Bool, membershipEnded: Bool,
                              connectionReady: Bool, playerAttached: Bool,
                              busy: Bool) -> String? {
        guard !busy else { return nil }
        guard hasRoom else { return "room-code" }
        if membershipEnded { return "leave" }
        if !connectionReady { return "reconnect" }
        return playerAttached ? "catch-up" : "choose-source"
    }
}
