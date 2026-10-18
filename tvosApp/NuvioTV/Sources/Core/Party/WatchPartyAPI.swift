import Foundation

// RPC contract: NuvioMedia/NuvioTV, GPL-3.0, PartyApi.kt
// at f7e2a78ad3b19a09080ad08315825f1f0a472934.

/// Captured by the future session owner; replace epoch on every membership/auth-context reset.
/// Tokens are deliberately not part of identity or equality.
struct WatchPartyRequestContext: Equatable, Sendable {
    let backendIdentity: String
    let userID: String
    let profileID: String?
    let epoch: UUID
}

struct WatchPartyIdentity: Equatable, Sendable {
    let deviceID: String
    let displayName: String
    var avatarURL: String? = nil
    var avatarColor: String? = nil
}

enum WatchPartyAPIError: Error, Equatable {
    case invalidConfiguration
    case staleContext
    case signInRequired
    case invalidCode
    case transport
    case invalidResponse
    case httpStatus(Int)
}

/// Foundation-only, inert until called. The owner supplies AuthManager's shared session path.
/// No refresh loop, automatic mutation retry, logs, Realtime client, or global singleton.
@MainActor
final class WatchPartyAPI {
    typealias SessionProvider = @MainActor () async -> AuthSession?
    typealias ContextValidator = @MainActor (WatchPartyRequestContext) -> Bool
    typealias Transport = @MainActor (URLRequest) async throws -> (Data, URLResponse)

    let context: WatchPartyRequestContext
    private let configuration: ServerConfiguration
    private let sessionProvider: SessionProvider
    private let isCurrent: ContextValidator
    private let transport: Transport

    init(configuration: ServerConfiguration, context: WatchPartyRequestContext,
         sessionProvider: @escaping SessionProvider, isCurrent: @escaping ContextValidator,
         transport: @escaping Transport = { request in try await URLSession.shared.data(for: request) }) {
        self.configuration = configuration
        self.context = context
        self.sessionProvider = sessionProvider
        self.isCurrent = isCurrent
        self.transport = transport
    }

    func create(identity: WatchPartyIdentity, media: WatchPartyMedia,
                playback: WatchPartyPlayback? = nil) async throws -> WatchPartySnapshot {
        var body = Body(identity: identity, media: media)
        body.playback = playback.map(PlaybackParameter.value) ?? .null
        return try await call("watch_party_create", body: body)
    }

    func join(code: String, identity: WatchPartyIdentity) async throws -> WatchPartySnapshot {
        let code = try validatedCode(code)
        return try await call("watch_party_join", body: Body(identity: identity, code: code))
    }

    func preview(code: String) async throws -> WatchPartyPreview {
        let code = try validatedCode(code)
        return try await call("watch_party_preview", body: Body(code: code))
    }

    func heartbeat(partyID: String, deviceID: String) async throws -> WatchPartySnapshot {
        try await call("watch_party_heartbeat", body: Body(partyID: partyID, deviceID: deviceID))
    }

    func update(partyID: String, deviceID: String, media: WatchPartyMedia? = nil,
                playback: WatchPartyPlayback? = nil) async throws -> WatchPartySnapshot {
        var body = Body(media: media, partyID: partyID, deviceID: deviceID)
        body.playback = playback.map(PlaybackParameter.value) ?? .omitted
        return try await call("watch_party_update", body: body)
    }

    func leave(partyID: String, deviceID: String) async throws -> WatchPartySnapshot {
        try await call("watch_party_leave", body: Body(partyID: partyID, deviceID: deviceID))
    }

    func end(partyID: String, deviceID: String) async throws -> WatchPartySnapshot {
        try await call("watch_party_end", body: Body(partyID: partyID, deviceID: deviceID))
    }

    func setHostOnly(partyID: String, deviceID: String, enabled: Bool) async throws -> WatchPartySnapshot {
        try await call("watch_party_set_host_only", body: Body(partyID: partyID, deviceID: deviceID, hostOnly: enabled))
    }

    func removeMember(partyID: String, deviceID: String, memberID: String) async throws -> WatchPartySnapshot {
        try await call("watch_party_remove_member", body: Body(partyID: partyID, deviceID: deviceID, memberID: memberID))
    }

    func clock() async throws -> Int64 { try await call("watch_party_clock", body: Body()) }
    func enabled() async throws -> Bool { try await call("watch_party_enabled", body: Body()) }

    private func validatedCode(_ code: String) throws -> String {
        let normalized = WatchPartyCode.normalize(code)
        guard normalized.count == WatchPartyCode.length else { throw WatchPartyAPIError.invalidCode }
        return normalized
    }

    private func checkContext() throws {
        try Task.checkCancellation()
        guard isCurrent(context) else { throw WatchPartyAPIError.staleContext }
    }

    private func endpoint(_ function: String) throws -> URL {
        guard configuration.backendIdentity == context.backendIdentity,
              !configuration.publishableKey.isEmpty,
              var components = URLComponents(string: configuration.normalizedBackendURL),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw WatchPartyAPIError.invalidConfiguration
        }
        components.scheme = scheme
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/").map(String.init).reduce("") { $0 + "/" + $1 }
            + "/rest/v1/rpc/" + function
        guard let url = components.url else { throw WatchPartyAPIError.invalidConfiguration }
        return url
    }

    private func call<Response: Decodable>(_ function: String, body: Body) async throws -> Response {
        try checkContext()
        let url = try endpoint(function)
        let session = await sessionProvider()
        try checkContext()
        guard let session, session.userId == context.userID, !session.accessToken.isEmpty,
              session.backendIdentity == context.backendIdentity
                || (session.backendIdentity == nil && configuration.backendIdentity == ServerDiscoveryPolicy.officialBackend) else {
            throw WatchPartyAPIError.signInRequired
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let result: (Data, URLResponse)
        do {
            result = try await transport(request)
        } catch {
            try checkContext()
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            // Do not retain an error containing a request URL, token, or response body.
            throw WatchPartyAPIError.transport
        }
        try checkContext()
        guard let response = result.1 as? HTTPURLResponse else { throw WatchPartyAPIError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw WatchPartyAPIError.httpStatus(response.statusCode) }
        do {
            return try JSONDecoder().decode(Response.self, from: result.0)
        } catch {
            // Business errors inside a successful snapshot are preserved for the session owner.
            throw WatchPartyAPIError.invalidResponse
        }
    }

    private enum PlaybackParameter {
        case omitted
        case null
        case value(WatchPartyPlayback)
    }

    private struct Body: Encodable {
        var identity: WatchPartyIdentity? = nil
        var code: String? = nil
        var media: WatchPartyMedia? = nil
        var partyID: String? = nil
        var deviceID: String? = nil
        var hostOnly: Bool? = nil
        var memberID: String? = nil
        var playback: PlaybackParameter = .omitted

        enum CodingKeys: String, CodingKey {
            case code = "p_code", media = "p_media", playback = "p_playback"
            case partyID = "p_party_id", deviceID = "p_device_id", hostOnly = "p_host_only", memberID = "p_member_id"
            case displayName = "p_display_name", avatarURL = "p_avatar_url", avatarColor = "p_avatar_color"
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            if let identity {
                try c.encode(identity.deviceID, forKey: .deviceID)
                try c.encode(identity.displayName, forKey: .displayName)
                if let url = identity.avatarURL { try c.encode(url, forKey: .avatarURL) }
                else { try c.encodeNil(forKey: .avatarURL) }
                if let color = identity.avatarColor { try c.encode(color, forKey: .avatarColor) }
                else { try c.encodeNil(forKey: .avatarColor) }
            } else {
                try c.encodeIfPresent(deviceID, forKey: .deviceID)
            }
            try c.encodeIfPresent(code, forKey: .code)
            try c.encodeIfPresent(media, forKey: .media)
            try c.encodeIfPresent(partyID, forKey: .partyID)
            try c.encodeIfPresent(hostOnly, forKey: .hostOnly)
            try c.encodeIfPresent(memberID, forKey: .memberID)
            switch playback {
            case .omitted: break
            case .null: try c.encodeNil(forKey: .playback)
            case .value(let value): try c.encode(value, forKey: .playback)
            }
        }
    }
}
