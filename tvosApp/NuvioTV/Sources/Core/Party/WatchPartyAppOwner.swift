import Foundation
import Combine

/// One root-owned composition, attached to ContentView's existing account/profile objects.
/// Construction and attachment do not create/join rooms, resolve sources or construct a player.
/// Player presentation and exact PiP lease restoration remain explicit launch transitions.
@MainActor
final class WatchPartyAppOwner: ObservableObject {
    @Published private(set) var service: WatchPartyService?
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

    /// Explicit root teardown; never use an asynchronous deinit for resource cleanup.
    func stop() {
        subscriptions.removeAll()
        observeRoom(nil)
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
        service.contextDidInvalidate.sink { [weak runtime] _ in
            MainActor.assumeIsolated { runtime?.invalidate() }
        }.store(in: &subscriptions)
        // @Published emits before the new pointer is installed. This also covers explicit
        // leave/replacement outside context invalidation. Do not adopt a new room implicitly.
        service.$session.dropFirst().sink { [weak self, weak service, weak runtime] next in
            MainActor.assumeIsolated {
                if service?.session !== next { runtime?.invalidate() }
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
                self.runtime?.invalidate()
            }
        }
    }
}
