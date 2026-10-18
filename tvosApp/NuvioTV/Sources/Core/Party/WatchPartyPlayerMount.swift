import Foundation

/// A checked pairing of owner and model. Construct at a launch/restore transition outside body.
/// SwiftUI must use a stable identity for this runtime, and a new identity for a new runtime.
@MainActor
struct WatchPartyPlayerMount {
    private let runtime: WatchPartyPlayerRuntime
    private let lease: WatchPartyPlayerRuntime.Lease

    var viewModel: PlayerViewModel { lease.resource }
    var isCurrent: Bool { runtime.isCurrent(lease) }

    init(runtime: WatchPartyPlayerRuntime, lease: WatchPartyPlayerRuntime.Lease) throws {
        guard runtime.isCurrent(lease) else { throw WatchPartyPlaybackRuntimeError.staleLease }
        self.runtime = runtime
        self.lease = lease
    }

    func attach() throws -> (surface: WatchPartyPlayerRuntime.Surface, startsLoad: Bool) {
        let surface = try runtime.attachFullscreen(lease)
        return (surface, try runtime.claimInitialLoad(surface))
    }

    @discardableResult
    func detach(_ surface: WatchPartyPlayerRuntime.Surface) -> Bool {
        let pip = PictureInPictureManager.shared
        let keepsPlayback = pip.activeCoordinator === viewModel.sessionCoordinator
            && (pip.isPictureInPictureActive || pip.isRestoringUIInProgress)
        return runtime.detachFullscreen(surface, keepingPictureInPicture: keepsPlayback)
    }

    func finish() { runtime.finish(lease) }
}

extension WatchPartyPlaybackRuntime where Resource == PlayerViewModel {
    /// The app root must retain this owner and invalidate it before account/profile/backend changes.
    static func player(isCurrent: @escaping @MainActor (WatchPartyPlaybackContext) -> Bool) -> WatchPartyPlayerRuntime {
        WatchPartyPlayerRuntime(isCurrent: isCurrent, stopResource: { $0.shutdownForWatchParty() })
    }

    /// A fresh launch explicitly creates its own coordinator, bypassing ambient PiP adoption.
    func beginPlayer(context: WatchPartyPlaybackContext) throws -> Lease {
        try begin(context: context) {
            PlayerViewModel(sessionCoordinator: PlaybackSessionCoordinator(), adoptsPictureInPictureSession: false)
        }
    }
}
