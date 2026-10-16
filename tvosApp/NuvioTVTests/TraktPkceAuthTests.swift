import XCTest
@testable import NuvioTV

/// Trakt dropped the client secret on 1-Oct-2026 (PR trakt/trakt-api#974): every
/// `/oauth` body now treats `client_secret` as optional/deprecated and secret-less
/// (PKCE-only) apps run the classic device flow by simply omitting it. These tests
/// lock that behavior so a PKCE-only Client ID (no secret) connects, while an app
/// that still has a legacy secret keeps sending it. OAuth now targets auth.trakt.tv.
final class TraktPkceAuthTests: XCTestCase {
    private var suiteName = ""
    private var profileID = ""
    private var store: UserDefaults!
    private var previousSettingsProfileID: String?
    private var previousSettingsProfileIsPrimary = false
    private var previousWatchedProfileID: String?

    override func setUp() {
        super.setUp()
        previousSettingsProfileID = ProfileSettings.activeProfileID
        previousSettingsProfileIsPrimary = ProfileSettings.isPrimaryProfileStore(ProfileSettings.current)
        previousWatchedProfileID = WatchedStore.activeProfileId
        profileID = "trakt-pkce-\(UUID().uuidString)"
        suiteName = "nuvio.tv.profile.settings.\(profileID)"
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        WatchedStore.eraseProfile(profileID)
        ProfileSettings.setActiveProfile(profileID, isPrimary: false)
        WatchedStore.setActiveProfile(profileID)
        store = ProfileSettings.current
        TraktStubURLProtocol.reset()
    }

    override func tearDown() {
        TraktStubURLProtocol.reset()
        WatchedStore.eraseProfile(profileID)
        if let previousWatchedProfileID {
            WatchedStore.setActiveProfile(previousWatchedProfileID)
        } else {
            WatchedStore.setActiveProfile(nil)
        }
        if let previousSettingsProfileID {
            ProfileSettings.setActiveProfile(
                previousSettingsProfileID,
                isPrimary: previousSettingsProfileIsPrimary
            )
        } else {
            ProfileSettings.clearActiveProfile()
        }
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - isConfigured

    func testIsConfiguredRequiresOnlyClientID() {
        store.set("YcBz-test-id", forKey: SettingsKey.traktClientID)
        // No client secret set — a PKCE-only app must still count as configured.
        XCTAssertTrue(TraktConfig.isConfigured(in: store))
    }

    func testIsConfiguredFalseWithoutClientID() {
        store.set("some-secret", forKey: SettingsKey.traktClientSecret)
        XCTAssertFalse(TraktConfig.isConfigured(in: store), "client_id is still required")
    }

    // MARK: - Device token exchange

    func testDeviceTokenExchangeOmitsClientSecretForSecretlessApp() async throws {
        store.set("YcBz-test-id", forKey: SettingsKey.traktClientID)
        seedActiveDeviceFlow(clientID: "YcBz-test-id")
        stubTokenSuccess()

        let service = TraktAuthService(session: stubbedSession(), store: store)
        let result = await service.pollDeviceToken()

        let tokenReq = try requireRequest(suffix: "oauth/device/token")
        XCTAssertEqual(tokenReq.url.host, "auth.trakt.tv", "OAuth must use the auth host")
        let body = try json(tokenReq.body)
        XCTAssertEqual(body["code"] as? String, "DEVCODE")
        XCTAssertEqual(body["client_id"] as? String, "YcBz-test-id")
        XCTAssertNil(body["client_secret"], "a secret-less app must NOT send client_secret")
        guard case .approved = result else {
            return XCTFail("expected .approved, got \(result)")
        }
    }

    func testDeviceTokenExchangeStillSendsLegacySecretWhenConfigured() async throws {
        store.set("legacy-id", forKey: SettingsKey.traktClientID)
        store.set("legacy-secret", forKey: SettingsKey.traktClientSecret)
        seedActiveDeviceFlow(clientID: "legacy-id")
        stubTokenSuccess()

        let service = TraktAuthService(session: stubbedSession(), store: store)
        _ = await service.pollDeviceToken()

        let tokenReq = try requireRequest(suffix: "oauth/device/token")
        let body = try json(tokenReq.body)
        XCTAssertEqual(body["client_secret"] as? String, "legacy-secret",
                       "an app that still has a secret keeps sending it")
    }

    // MARK: - Refresh

    func testApprovalAfterDeviceFlowWasClearedDoesNotAuthenticate() async throws {
        let store = try XCTUnwrap(self.store)
        store.set("cancel-test-id", forKey: SettingsKey.traktClientID)
        seedActiveDeviceFlow(clientID: "cancel-test-id")
        TraktStubURLProtocol.responder = { _ in
            TraktAuthStore.clearDeviceFlow(store: store)
            return (200, Data("""
                {"access_token":"late-access","token_type":"Bearer","expires_in":3600,"refresh_token":"late-refresh","created_at":2}
                """.utf8))
        }

        let result = await TraktAuthService(session: stubbedSession(), store: store).pollDeviceToken()

        guard case .failed = result else { return XCTFail("Expected obsolete approval to be rejected") }
        XCTAssertNil(TraktAuthStore.state(in: store).accessToken)
        XCTAssertFalse(TraktAuthStore.isAuthenticated(in: store))
    }

    func testLatePollResponsesCannotClearOrSlowDownReplacementFlow() async throws {
        let store = try XCTUnwrap(self.store)
        store.set("replacement-test-id", forKey: SettingsKey.traktClientID)
        for status in [400, 409, 410, 418, 429] {
            seedActiveDeviceFlow(clientID: "replacement-test-id")
            TraktStubURLProtocol.responder = { _ in
                TraktAuthStore.saveDeviceFlow(
                    TraktDeviceCodeResponse(deviceCode: "NEWCODE", userCode: "NEWUSER",
                                            verificationURL: "https://trakt.tv/activate",
                                            expiresIn: 600, interval: 7),
                    clientID: "replacement-test-id", store: store
                )
                return (status, Data("{}".utf8))
            }

            let result = await TraktAuthService(session: stubbedSession(), store: store).pollDeviceToken()

            guard case .failed = result else { return XCTFail("Expected obsolete status \(status) to be rejected") }
            let state = TraktAuthStore.state(in: store)
            XCTAssertEqual(state.deviceCode, "NEWCODE", "status \(status)")
            XCTAssertEqual(state.userCode, "NEWUSER")
            XCTAssertEqual(state.pollInterval, 7)
            XCTAssertNil(state.accessToken)
        }
    }

    func testAlreadyCancelledPollDoesNotStartTokenRequest() async throws {
        store.set("cancel-test-id", forKey: SettingsKey.traktClientID)
        seedActiveDeviceFlow(clientID: "cancel-test-id")
        stubTokenSuccess()
        let service = TraktAuthService(session: stubbedSession(), store: store)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await service.pollDeviceToken()
        }

        let result = await task.value

        guard case .failed = result else { return XCTFail("Expected cancelled polling to stop") }
        XCTAssertTrue(TraktStubURLProtocol.captured.isEmpty)
        XCTAssertNil(TraktAuthStore.state(in: store).accessToken)
    }

    func testRefreshOmitsClientSecretForSecretlessApp() async throws {
        store.set("YcBz-test-id", forKey: SettingsKey.traktClientID)
        TraktAuthStore.saveToken(
            TraktTokenResponse(
                accessToken: "old-access",
                tokenType: "Bearer",
                expiresIn: 7_776_000,
                refreshToken: "old-refresh",
                createdAt: 1
            ),
            clientID: "YcBz-test-id",
            store: store
        )
        store.set(true, forKey: SettingsKey.traktConnected)
        stubTokenSuccess()

        let service = TraktAuthService(session: stubbedSession(), store: store)
        let ok = await service.refreshTokenIfNeeded(force: true)

        XCTAssertTrue(ok)
        let refreshReq = try requireRequest(suffix: "oauth/token")
        XCTAssertEqual(refreshReq.url.host, "auth.trakt.tv")
        let body = try json(refreshReq.body)
        XCTAssertNil(body["client_secret"], "a secret-less app must NOT send client_secret on refresh")
        XCTAssertEqual(body["refresh_token"] as? String, "old-refresh")
        XCTAssertEqual(body["client_id"] as? String, "YcBz-test-id")
        XCTAssertEqual(body["grant_type"] as? String, "refresh_token")
    }

    // MARK: - Helpers

    private func seedActiveDeviceFlow(clientID: String) {
        TraktAuthStore.saveDeviceFlow(
            TraktDeviceCodeResponse(
                deviceCode: "DEVCODE",
                userCode: "USER",
                verificationURL: "https://trakt.tv/activate",
                expiresIn: 600,
                interval: 0
            ),
            clientID: clientID,
            store: store
        )
    }

    private func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TraktStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func stubTokenSuccess() {
        TraktStubURLProtocol.responder = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("device/token") || path.hasSuffix("oauth/token") {
                let tokenJSON = """
                {"access_token":"new-access","token_type":"Bearer","expires_in":7776000,"refresh_token":"new-refresh","created_at":2}
                """
                return (200, Data(tokenJSON.utf8))
            }
            // users/settings and anything else: harmless empty object.
            return (200, Data("{}".utf8))
        }
    }

    private func requireRequest(suffix: String) throws -> TraktStubURLProtocol.Captured {
        let match = TraktStubURLProtocol.captured.first { $0.url.path.hasSuffix(suffix) }
        return try XCTUnwrap(match, "no request captured for \(suffix)")
    }

    private func json(_ data: Data?) throws -> [String: Any] {
        let data = try XCTUnwrap(data, "request had no body")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

/// Captures outgoing requests (URLSession moves `httpBody` into `httpBodyStream`,
/// so drain the stream) and returns canned responses. Test-only.
final class TraktStubURLProtocol: URLProtocol {
    struct Captured {
        let url: URL
        let body: Data?
    }

    static var captured: [Captured] = []
    static var responder: ((URLRequest) -> (Int, Data))?

    static func reset() {
        captured = []
        responder = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url {
            TraktStubURLProtocol.captured.append(
                Captured(url: url, body: Self.readBody(from: request))
            )
        }
        let (status, data) = TraktStubURLProtocol.responder?(request) ?? (200, Data())
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
