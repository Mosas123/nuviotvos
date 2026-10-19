import SwiftUI

/// Watch Party controls embedded in the player's InSight panel.
@MainActor
struct PlayerWatchPartyPanel: View {
    @ObservedObject var viewModel: PlayerViewModel
    @ObservedObject var owner: WatchPartyAppOwner
    @ObservedObject var service: WatchPartyService
    @FocusState.Binding var focusedControlID: String?
    let onOpenLobby: () -> Void

    @State private var operation: Task<Void, Never>?
    @State private var message: String?
    @State private var endingRoom = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if let room = service.session, let party = room.party {
                    roomRows(room, party: party)
                } else {
                    PlayerPanelRow(
                        title: "Watch Party",
                        subtitle: service.membershipOutcomeUncertain
                            ? "Check the room status before trying again."
                            : "Create or join a room in the Watch Party lobby."
                    )
                    openLobbyButton
                    if service.session?.membershipExit != nil {
                        PlayerPanelRow(title: "Your previous room membership ended. Joining again needs a new request.")
                    }
                }

                if service.busy || operation != nil { ProgressView("Contacting room…") }
                if let message { PlayerPanelRow(title: message) }
                if let message = owner.message { PlayerPanelRow(title: message) }
                if let failure = service.failure { PlayerPanelRow(title: failureText(failure)) }
            }
        }
        .onAppear {
            focusedControlID = owner.presentation?.mount.isCurrent == true ? "party.catchUp" : "party.lobby"
        }
        .confirmationDialog("End this room for everyone?", isPresented: $endingRoom) {
            Button("End room", role: .destructive) {
                owner.finishPlayback(reportBrowsing: false)
                run { try await service.leave(endForEveryone: true) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var openLobbyButton: some View {
        Button(action: onOpenLobby) {
            PlayerPanelRow(title: "Open Watch Party lobby", subtitle: "Create a room or join with an invitation code.")
        }
        .buttonStyle(PosterCardButtonStyle())
        .focusEffectDisabledIfAvailable()
        .focused($focusedControlID, equals: "party.lobby")
        .disabled(operation != nil)
    }

    @ViewBuilder
    private func roomRows(_ room: WatchPartySession, party: WatchPartyInfo) -> some View {
        PlayerPanelRow(title: "Room code", subtitle: connectionText(room.connection), trailing: party.code)
        if !party.media.title.isEmpty { PlayerPanelRow(title: party.media.title) }
        ForEach(room.members, id: \.id) { member in
            let role = member.id == room.memberID ? "You" : (member.id == party.hostMemberID ? "Host" : nil)
            PlayerPanelRow(
                title: member.displayName,
                subtitle: room.presence[member.id]?.status.rawValue ?? "browsing",
                trailing: role
            )
        }

        if owner.presentation?.mount.isCurrent == true {
            Button { viewModel.catchUpWithWatchParty() } label: {
                PlayerPanelRow(title: "Catch up with room", subtitle: "Jump to the room's current position.")
            }
            .buttonStyle(PosterCardButtonStyle())
            .focusEffectDisabledIfAvailable()
            .focused($focusedControlID, equals: "party.catchUp")
            .disabled(service.busy || room.connection != .ready)
        } else {
            PlayerPanelRow(title: "Choose your source from the Watch Party lobby to start playback.")
            openLobbyButton
        }

        if room.connection != .ready, room.membershipExit == nil {
            Button("Reconnect this room") { run { try await service.resume() } }
                .buttonStyle(PosterCardButtonStyle())
                .disabled(service.busy || operation != nil)
        }
        Button("Leave room") {
            owner.finishPlayback(reportBrowsing: false)
            run { try await service.leave() }
        }
        .buttonStyle(PosterCardButtonStyle())
        .disabled(service.busy || operation != nil)

        if party.hostMemberID == room.memberID {
            Button("End room for everyone", role: .destructive) { endingRoom = true }
                .buttonStyle(PosterCardButtonStyle())
                .disabled(service.busy || operation != nil)
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !service.busy, operation == nil else { return }
        message = nil
        operation = Task { @MainActor in
            defer { operation = nil }
            do { try await action() }
            catch { if !Task.isCancelled { message = "Could not complete the room request. Check its status before trying again." } }
        }
    }

    private func connectionText(_ state: WatchPartyConnectionState) -> String {
        switch state {
        case .ready: return "Connected"
        case .connecting, .reconciling: return "Synchronizing room…"
        case .recovering: return "Connection lost — recovering this membership…"
        case .stopped: return "Room disconnected"
        }
    }

    private func failureText(_ failure: WatchPartyFailure) -> String {
        switch failure {
        case .invalidCode: return "Enter a valid room code."
        case .notFound: return "Room not found. Check the invitation code."
        case .full: return "This room is full."
        case .removed: return "You were removed from this room."
        case .ended: return "This room has ended."
        case .rateLimited: return "Too many requests. Wait before trying again."
        case .signInRequired: return "Sign in again to use Watch Party."
        case .unavailable: return "Watch Party is unavailable on this server."
        case .network: return "The room request failed. Check your connection and room status."
        }
    }
}
