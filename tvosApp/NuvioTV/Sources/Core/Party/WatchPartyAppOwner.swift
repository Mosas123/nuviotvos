import Foundation
import Combine

/// One root-owned composition, attached to ContentView's existing account/profile objects.
/// Construction and attachment do not create/join rooms, resolve sources or construct a player.
/// Player presentation and exact PiP lease restoration remain explicit launch transitions.
@MainActor
final class WatchPartyAppOwner: ObservableObject {
    struct Presentation: Identifiable {
        let id: UUID
        let mount: WatchPartyPlayerMount
        let context: WatchPartyPlaybackContext
    }
    @Published private(set) var service: WatchPartyService?
    @Published private(set) var presentation: Presentation?
    @Published var message: String?
    private var lease: WatchPartyPlayerRuntime.Lease?
    private var browsingTask: Task<Void, Never>?
    private(set) var runtime: WatchPartyPlayerRuntime?
    private weak var authManager: AuthManager?
    private weak var profiles: ProfileViewModel?
    private var subscriptions: Set<AnyCancellable> = []
    private weak var observedRoom: WatchPartySession?
    private var roomObserverID: UUID?

    init() {}

    /// Injection keeps context-boundary tests independent of Auth/Keychain/network/player engines.
    init(service: WatchPartyService, contextChanges: AnyPublisher<Void, Never>) {
        configure(service: service, contextChanges: contextChanges)
    }

    func attach(authManager: AuthManager, profiles: ProfileViewModel) {
        if self.authManager === authManager, self.profiles === profiles, service != nil { return }
        stop()
        self.authManager = authManager
        self.profiles = profiles
        let service = WatchPartyService.authenticated(
            authManager: authManager, deviceID: SyncClientIdentity.current(),
            profile: { [weak profiles] in
                guard let profile = profiles?.activeProfile else { return nil }
                return WatchPartyProfileIdentity(id: profile.id, name: profile.name)
            }
        )
        configure(service: service, contextChanges: authManager.contextWillChange
            .merge(with: profiles.contextWillChange).eraseToAnyPublisher())
    }

    /// Explicit privacy gate (e.g. who's-watching on return) may revoke the same profile, too.
    func invalidateContext() { service?.invalidateContext() }

    /// Only after an explicit, own-source choice for this exact accepted room/media.
    func preparePlayback(media: WatchPartyMedia) throws -> Presentation {
        guard let service, let room = service.session, room.connection == .ready,
              let context = room.playbackContext, context.mediaKey == media.key,
              service.isCurrent(context.request), let runtime else {
            throw WatchPartyPlaybackRuntimeError.staleContext
        }
        finishPlayback(reportBrowsing: false)
        browsingTask?.cancel(); browsingTask = nil
        let lease = try runtime.beginPlayer(context: context)
        do {
            _ = try runtime.bindPlayback(lease, room: room)
            let id = UUID()
            let mount = try WatchPartyPlayerMount(runtime: runtime, lease: lease, onDetached: { [weak self] in
                guard self?.presentation?.id == id else { return }
                self?.finishPlayback()
            })
            let result = Presentation(id: id, mount: mount, context: context)
            self.lease = lease
            presentation = result
            message = nil
            return result
        } catch { runtime.finish(lease); throw error }
    }

    func owns(_ coordinator: PlaybackSessionCoordinator?) -> Bool {
        guard let coordinator, let lease else { return false }
        return lease.resource.sessionCoordinator === coordinator
    }

    func restorePlayback(for coordinator: PlaybackSessionCoordinator?) -> Presentation? {
        guard owns(coordinator), let presentation, let runtime,
              (try? runtime.restore(context: presentation.context)) != nil,
              presentation.mount.isCurrent else { return nil }
        return presentation
    }

    func resumeAfterForeground() {
        guard let presentation, presentation.mount.isCurrent else { return }
        presentation.mount.viewModel.resumeWatchPartyAfterForeground()
    }

    func suspendForInactivity() {
        guard let presentation, presentation.mount.isCurrent else { return }
        presentation.mount.viewModel.suspendWatchPartyForLifecycle()
    }

    func finishPlayback(reportBrowsing: Bool = true) {
        let context = lease?.context
        let oldRuntime = runtime
        lease = nil
        presentation = nil
        browsingTask?.cancel(); browsingTask = nil
        oldRuntime?.invalidate()
        guard reportBrowsing, let context, let service, let room = service.session,
              service.isCurrent(context.request), room.playbackContext == context else { return }
        browsingTask = Task { [weak self, weak service, weak room] in
            guard !Task.isCancelled, let service, let room,
                  service.isCurrent(context.request), room.playbackContext == context,
                  self?.lease == nil else { return }
            do { try await room.setPresence(status: .browsing, mediaKey: nil, behindMs: nil) }
            catch { if !Task.isCancelled { self?.message = "Could not update your room status." } }
        }
    }

    /// Explicit root teardown; never use an asynchronous deinit for resource cleanup.
    func stop() {
        subscriptions.removeAll()
        observeRoom(nil)
        finishPlayback(reportBrowsing: false)
        let oldRuntime = runtime
        let oldService = service
        runtime = nil
        service = nil
        authManager = nil
        profiles = nil
        oldRuntime?.invalidate()
        oldService?.invalidateContext()
    }

    private func configure(service: WatchPartyService, contextChanges: AnyPublisher<Void, Never>) {
        self.service = service
        let runtime = WatchPartyPlayerRuntime.player { [weak service] context in
            guard let service, service.isCurrent(context.request) else { return false }
            return service.session?.playbackContext == context
        }
        self.runtime = runtime
        // Subjects are emitted synchronously by @MainActor AuthManager/ProfileViewModel.
        // No receive(on:) or Task: these must finish before credentials/store scope mutate.
        contextChanges.sink { [weak service] _ in
            MainActor.assumeIsolated { service?.invalidateContext() }
        }.store(in: &subscriptions)
        service.contextDidInvalidate.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.finishPlayback(reportBrowsing: false) }
        }.store(in: &subscriptions)
        // @Published emits before the new pointer is installed. This also covers explicit
        // leave/replacement outside context invalidation. Do not adopt a new room implicitly.
        service.$session.dropFirst().sink { [weak self, weak service] next in
            MainActor.assumeIsolated {
                if service?.session !== next { self?.finishPlayback(reportBrowsing: false) }
                self?.observeRoom(next)
            }
        }.store(in: &subscriptions)
        observeRoom(service.session)
    }

    private func observeRoom(_ room: WatchPartySession?) {
        if let roomObserverID { observedRoom?.removeChangeObserver(roomObserverID) }
        roomObserverID = nil
        observedRoom = room
        guard let room else { return }
        roomObserverID = room.observeChanges { [weak self, weak room] in
            guard let self, let context = self.runtime?.currentContext else { return }
            if room?.playbackContext != context {
                // Membership/media changes close the old player; source resolution is a later,
                // explicit transition. No automatic reuse of its URL or host-provided link.
                self.finishPlayback(reportBrowsing: false)
                if room?.playbackContext != nil { self.message = "The room changed title. Choose your source again." }
            }
        }
    }
}
