import SwiftUI

/// Private rooms; every participant explicitly selects their own compatible source.
/// Received shared-stream links are deliberately not resolved or played by this MVP.
@MainActor
struct WatchPartyLobbyView: View {
    @ObservedObject var owner: WatchPartyAppOwner
    @ObservedObject var service: WatchPartyService
    let canUseAccount: Bool
    let isChoosing: Bool
    let onCreate: () -> Void
    let onChooseSource: (WatchPartyMedia) -> Void
    let onCancelSelection: () -> Void
    @State private var code = ""
    @State private var operation: Task<Void, Never>?
    @State private var endingRoom = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Watch Party").font(.largeTitle.bold())
                Text("Private rooms. Each viewer uses their own source of the same edition.")
                if !canUseAccount {
                    Text("Sign in and choose a profile to use Watch Party.")
                } else if let room = service.session, let party = room.party {
                    Text("Room code: \(party.code)").font(.title.monospaced())
                    Text(party.media.title.isEmpty ? "Room title" : party.media.title).font(.title2)
                    if let season = party.media.season, let episode = party.media.episode {
                        Text("Season \(season) · Episode \(episode)")
                    }
                    Text(connectionText(room.connection))
                    ForEach(room.members, id: \.id) { member in
                        Text("\(member.displayName) · \(room.presence[member.id]?.status.rawValue ?? "browsing")")
                    }
                    if owner.presentation != nil {
                        Text("Playback is open. Use the PiP restore button to return to the same player.")
                        Button("Catch up with room") {
                            guard let presentation = owner.presentation, presentation.mount.isCurrent else { return }
                            presentation.mount.viewModel.catchUpWithWatchParty()
                        }.disabled(service.busy || room.connection != .ready)
                    } else {
                        Button("I have the same edition — choose my source") { onChooseSource(party.media) }
                            .disabled(service.busy || room.connection != .ready || room.membershipExit != nil)
                    }
                    if room.connection != .ready, room.membershipExit == nil {
                        Button("Reconnect this room") { run { try await service.resume() } }
                            .disabled(service.busy)
                    }
                    if room.membershipExit != nil {
                        Text("This membership ended. Leave this room before joining again.")
                    }
                    Button("Leave room") {
                        onCancelSelection(); owner.finishPlayback()
                        run { try await service.leave() }
                    }.disabled(service.busy)
                    if party.hostMemberID == room.memberID {
                        Button("End room for everyone") { endingRoom = true }.disabled(service.busy)
                    }
                } else {
                    if service.session?.membershipExit != nil {
                        Text("Your previous room membership ended. Joining again requires a new request.")
                    }
                    Button("Create room — choose a title") {
                        owner.message = nil
                        onCreate()
                    }.disabled(service.busy || service.membershipOutcomeUncertain)
                    Text("Your room starts paused. Press Play once your source is ready.")
                    TextField("Room code", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .frame(maxWidth: 600)
                    Button("Join private room") {
                        onCancelSelection()
                        run { try await service.join(code: code) }
                    }.disabled(service.busy || !WatchPartyCode.isValid(code) || service.membershipOutcomeUncertain)
                    if service.membershipOutcomeUncertain {
                        Text("The server may have accepted the last request. Check the room with its host before trying again.")
                        Button("I checked — allow a new attempt") { service.acknowledgeUncertainMembershipOutcome() }
                    }
                }
                if isChoosing {
                    Text("Choose the room's exact movie or episode. Playback uses the built-in player.")
                    Button("Cancel title/source selection", action: onCancelSelection)
                }
                if service.busy { ProgressView("Contacting room…") }
                if let message = owner.message { Text(message).foregroundStyle(.orange) }
                if service.failure != nil {
                    Text(failureText(service.failure))
                        .foregroundStyle(.orange)
                }
                Text("Episode changes, autoplay and shared links are unavailable in this first version.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(60)
            .frame(maxWidth: 1300, alignment: .leading)
        }
        .confirmationDialog("End this room for everyone?", isPresented: $endingRoom) {
            Button("End room", role: .destructive) {
                onCancelSelection(); owner.finishPlayback()
                run { try await service.leave(endForEveryone: true) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !service.busy, operation == nil else { return }
        owner.message = nil
        operation = Task { @MainActor in
            defer { operation = nil }
            do { try await action() }
            catch { if !Task.isCancelled { owner.message = "Could not complete the room request. Review the room status before trying again." } }
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

    private func failureText(_ failure: WatchPartyFailure?) -> String {
        switch failure {
        case .notFound: return "Room not found. Check the invitation code."
        case .full: return "This room is full."
        case .removed: return "You were removed from this room."
        case .ended: return "This room has ended."
        case .rateLimited: return "Too many requests. Wait before trying again."
        case .signInRequired: return "Sign in again to use Watch Party."
        case .unavailable: return "Watch Party is unavailable on this server."
        case .network, .none: return "The room request failed. Check your connection and room status before trying again."
        }
    }
}
