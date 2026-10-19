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
    @State private var showingInviteCode = false

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
                            : "Join a room using an invitation code from the Watch Party tab."
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
            // Start at the visible invitation row, not an off-screen action.
            focusedControlID = service.session?.party != nil ? "party.invite" : "party.lobby"
        }
        .sheet(isPresented: $showingInviteCode) {
            if let party = service.session?.party, WatchPartyCode.isValid(party.code) {
                WatchPartyInviteSheet(code: WatchPartyCode.normalize(party.code))
            }
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
            PlayerPanelRow(title: "Open Watch Party tab", subtitle: "Join by code or choose your own source for this room.")
        }
        .buttonStyle(PosterCardButtonStyle())
        .focusEffectDisabledIfAvailable()
        .focused($focusedControlID, equals: "party.lobby")
        .disabled(operation != nil)
    }

    @ViewBuilder
    private func roomRows(_ room: WatchPartySession, party: WatchPartyInfo) -> some View {
        roomOverview(room, party: party)
        participantOverview(room, party: party)
        Button { showingInviteCode = true } label: {
            PlayerPanelRow(
                title: "Invite a friend",
                subtitle: "Show the room code to invite someone."
            )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focusEffectDisabledIfAvailable()
        .focused($focusedControlID, equals: "party.invite")
        PlayerPanelRow(
            title: "Playback controls",
            subtitle: party.hostOnly ? "Only the host can control playback." : "Participants can control playback."
        )

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

    /// Server-issued code and membership information; never a source URL.
    private func roomOverview(_ room: WatchPartySession, party: WatchPartyInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ROOM CODE")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(connectionText(room.connection))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            }
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(WatchPartyCode.formatted(party.code))
                    .font(.system(size: 31, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 8)
                Text(party.hostMemberID == room.memberID ? "HOST" : "GUEST")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            Text(party.media.title.isEmpty ? "Watch Party room" : party.media.title)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
            if let season = party.media.season, let episode = party.media.episode {
                Text("Season \(season) · Episode \(episode)")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
    }

    private func participantOverview(_ room: WatchPartySession, party: WatchPartyInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Participants")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(room.members.count) / \(party.maxMembers)")
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
            }
            if room.members.isEmpty {
                Text("Waiting for participants…")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                ForEach(room.members, id: \.id) { member in
                    let isHost = member.id == party.hostMemberID
                    let isMe = member.id == room.memberID
                    PlayerPanelRow(
                        title: member.displayName.isEmpty ? "Viewer" : member.displayName,
                        subtitle: participantStatus(room.presence[member.id]?.status),
                        trailing: isHost ? (isMe ? "Host · You" : "Host") : (isMe ? "You" : nil)
                    )
                }
            }
        }
    }

    private func participantStatus(_ status: WatchPartyMemberStatus?) -> String {
        switch status ?? .browsing {
        case .browsing: return "Browsing"
        case .loading: return "Choosing a source"
        case .buffering: return "Buffering"
        case .ready: return "Ready to watch"
        case .behind: return "Catching up"
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

@MainActor
private struct WatchPartyInviteSheet: View {
    let code: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var dismissFocused: Bool

    private var inviteLink: String { "nuvio://party/\(code)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Invite a friend")
                .font(.system(size: 38, weight: .bold, design: .rounded))
            HStack(alignment: .center, spacing: 32) {
                if let image = QRCode.image(from: inviteLink, scale: 12) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 260, height: 260)
                        .padding(12)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityLabel("QR code for joining Watch Party room \(code)")
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("Scan with a compatible Nuvio app")
                        .font(.system(size: 22, weight: .semibold))
                    Text(WatchPartyCode.formatted(code))
                        .font(.system(size: 37, weight: .bold, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text("Or enter this code in Watch Party. Each guest can choose their own source.")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .focused($dismissFocused)
            }
        }
        .padding(44)
        .frame(width: 760)
        .onAppear { dismissFocused = true }
        .onExitCommand { dismiss() }
    }
}
