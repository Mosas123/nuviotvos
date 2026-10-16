import XCTest
@testable import NuvioTV

final class TraktDeviceStartOwnershipTests: XCTestCase {
    private var profileID = ""
    private var otherProfileID = ""
    private var store: UserDefaults!
    private var previousProfileID: String?
    private var previousPrimary = false

    override func setUp() {
        super.setUp()
        previousProfileID = ProfileSettings.activeProfileID
        previousPrimary = ProfileSettings.isPrimaryProfileStore(ProfileSettings.current)
        profileID = "trakt-start-\(UUID().uuidString)"
        otherProfileID = "trakt-start-other-\(UUID().uuidString)"
        ProfileSettings.setActiveProfile(profileID, isPrimary: false)
        store = ProfileSettings.current
        store.set("test-client", forKey: SettingsKey.traktClientID)
        TraktDeviceStartURLProtocol.reset()
    }

    override func tearDown() {
        TraktDeviceStartURLProtocol.reset()
        if let previousProfileID {
            ProfileSettings.setActiveProfile(previousProfileID, isPrimary: previousPrimary)
        } else {
            ProfileSettings.clearActiveProfile()
        }
        for id in [profileID, otherProfileID] {
            UserDefaults.standard.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(id)")
        }
        super.tearDown()
    }

    @MainActor
    func testNormalSecretlessStartSavesDeviceFlow() async throws {
        let response = try await service().startDeviceAuth()
        XCTAssertEqual(response.deviceCode, "RESPONSE-CODE")
        XCTAssertEqual(TraktAuthStore.state(in: store).deviceCode, "RESPONSE-CODE")
        XCTAssertEqual(TraktAuthStore.state(in: store).credentialClientID, "test-client")
        XCTAssertEqual(TraktDeviceStartURLProtocol.requestCount, 1)
    }

    @MainActor
    func testClearedFlowRejectsInFlightStartResponse() async {
        TraktDeviceStartURLProtocol.beforeResponse = { [store = store!] in
            TraktAuthStore.clearDeviceFlow(store: store)
        }
        await assertSupersededStart()
        XCTAssertNil(TraktAuthStore.state(in: store).deviceCode)
    }

    @MainActor
    func testNewFlowIsNotOverwrittenByOldStartResponse() async {
        TraktDeviceStartURLProtocol.beforeResponse = { [store = store!] in
            TraktAuthStore.saveDeviceFlow(Self.flow(code: "NEW-CODE"), clientID: "test-client", store: store)
        }
        await assertSupersededStart()
        XCTAssertEqual(TraktAuthStore.state(in: store).deviceCode, "NEW-CODE")
    }

    @MainActor
    func testNewLoginInvalidatesPendingStart() async {
        TraktDeviceStartURLProtocol.beforeResponse = { [store = store!] in
            TraktAuthStore.saveToken(TraktTokenResponse(accessToken: "new-access", tokenType: "Bearer",
                                                       expiresIn: 3600, refreshToken: "new-refresh",
                                                       createdAt: Int(Date().timeIntervalSince1970)),
                                     clientID: "test-client", store: store, isNewLogin: true)
        }
        await assertSupersededStart()
        XCTAssertNil(TraktAuthStore.state(in: store).deviceCode)
        XCTAssertEqual(TraktAuthStore.state(in: store).accessToken, "new-access")
    }

    @MainActor
    func testProfileSwitchRejectsOldStartResponse() async {
        TraktDeviceStartURLProtocol.beforeResponse = { [otherProfileID] in
            ProfileSettings.setActiveProfile(otherProfileID, isPrimary: false)
        }
        await assertSupersededStart()
        XCTAssertNil(TraktAuthStore.state(in: store).deviceCode)
        XCTAssertNil(TraktAuthStore.state(in: ProfileSettings.current).deviceCode)
    }

    @MainActor
    func testClientIDChangeRejectsOldStartResponse() async {
        TraktDeviceStartURLProtocol.beforeResponse = { [store = store!] in
            store.set("replacement-client", forKey: SettingsKey.traktClientID)
        }
        await assertSupersededStart()
        XCTAssertNil(TraktAuthStore.state(in: store).deviceCode)
    }

    @MainActor
    func testUnexpiredFlowIsReusedWithoutRequest() async throws {
        TraktAuthStore.saveDeviceFlow(Self.flow(code: "EXISTING"), clientID: "test-client", store: store)
        let response = try await service().startDeviceAuth()
        XCTAssertEqual(response.deviceCode, "EXISTING")
        XCTAssertEqual(TraktDeviceStartURLProtocol.requestCount, 0)
    }

    @MainActor
    func testCancelReleasesLoadingAndAllowsAnotherConnectWithoutStaleUI() async throws {
        let viewModel = TraktSettingsViewModel(store: store, session: session())
        for _ in 0..<2 {
            viewModel.connect()
            let task = try XCTUnwrap(viewModel.connectionTask)
            XCTAssertTrue(viewModel.isLoading)
            viewModel.cancelDeviceFlow()
            await task.value
            XCTAssertFalse(viewModel.isLoading)
            XCTAssertFalse(viewModel.isPolling)
            XCTAssertNil(viewModel.connectionTask)
            XCTAssertNil(viewModel.deviceUserCode)
            XCTAssertNil(viewModel.errorMessage)
            if case .disconnected = viewModel.mode {} else { XCTFail("Cancel restored a login screen") }
        }
        XCTAssertEqual(TraktDeviceStartURLProtocol.requestCount, 0)
    }

    @MainActor
    private func assertSupersededStart(file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await service().startDeviceAuth()
            XCTFail("Expected a superseded start to be rejected", file: file, line: line)
        } catch is CancellationError {
            // Expected; a late response must not persist its device code.
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
        XCTAssertEqual(TraktDeviceStartURLProtocol.requestCount, 1, file: file, line: line)
    }

    private func service() -> TraktAuthService { TraktAuthService(session: session(), store: store) }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TraktDeviceStartURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func flow(code: String) -> TraktDeviceCodeResponse {
        TraktDeviceCodeResponse(deviceCode: code, userCode: "USER", verificationURL: "https://trakt.tv/activate",
                                expiresIn: 600, interval: 5)
    }
}

private final class TraktDeviceStartURLProtocol: URLProtocol {
    static var beforeResponse: (() -> Void)?
    static var requestCount = 0

    static func reset() {
        beforeResponse = nil
        requestCount = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Task { @MainActor [self] in
            Self.requestCount += 1
            Self.beforeResponse?()
            let data = Data("""
            {"device_code":"RESPONSE-CODE","user_code":"RESPONSE-USER","verification_url":"https://trakt.tv/activate","expires_in":600,"interval":5}
            """.utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
