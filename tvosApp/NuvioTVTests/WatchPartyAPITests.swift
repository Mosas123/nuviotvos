import XCTest
@testable import NuvioTV

@MainActor
final class WatchPartyAPITests: XCTestCase {
    private let backend = "https://party.example.test/prefix"
    private let identity = WatchPartyIdentity(deviceID: "device", displayName: "Viewer")
    private let media = WatchPartyMedia(type: "movie", metaID: "tt1", metaType: "movie")

    private func configuration(_ url: String? = nil) -> ServerConfiguration {
        ServerConfiguration(backendURL: url ?? backend, publishableKey: "public-test-key",
                            capabilities: ServerCapabilities(), discoveryURL: nil)
    }

    private func context(_ url: String? = nil) -> WatchPartyRequestContext {
        WatchPartyRequestContext(backendIdentity: url ?? backend, userID: "user", profileID: "profile", epoch: UUID())
    }

    private func session(_ url: String? = nil) -> AuthSession {
        AuthSession(accessToken: "test-token", refreshToken: "unused", userId: "user",
                    email: nil, expiresAt: nil, backendIdentity: url ?? backend)
    }

    private func response(_ request: URLRequest, body: String = "{}", status: Int = 200) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    private func object(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    func testCreateUsesExplicitNullWhileUpdateOmitsAbsentParameters() async throws {
        var requests: [URLRequest] = []
        let api = WatchPartyAPI(configuration: configuration(), context: context(), sessionProvider: { self.session() },
                                isCurrent: { _ in true }, transport: { request in
            requests.append(request)
            return self.response(request)
        })
        _ = try await api.create(identity: identity, media: media)
        _ = try await api.update(partyID: "room", deviceID: "device")
        let create = try object(requests[0])
        XCTAssertTrue(create["p_playback"] is NSNull)
        XCTAssertTrue(create["p_avatar_url"] is NSNull)
        XCTAssertTrue(create["p_avatar_color"] is NSNull)
        XCTAssertNotNil(create["p_media"])
        let update = try object(requests[1])
        XCTAssertEqual(Set(update.keys), ["p_party_id", "p_device_id"])
        XCTAssertEqual(requests[0].url?.absoluteString, backend + "/rest/v1/rpc/watch_party_create")
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "apikey"), "public-test-key")
    }

    func testAllOtherRPCNamesKeysAndScalarResponses() async throws {
        var requests: [URLRequest] = []
        let api = WatchPartyAPI(configuration: configuration(), context: context(), sessionProvider: { self.session() },
                                isCurrent: { _ in true }, transport: { request in
            requests.append(request)
            switch request.url!.lastPathComponent {
            case "watch_party_clock": return self.response(request, body: "9007199254740993")
            case "watch_party_enabled": return self.response(request, body: "true")
            default: return self.response(request)
            }
        })
        _ = try await api.join(code: "abc-234", identity: identity)
        _ = try await api.preview(code: "abc 234")
        _ = try await api.heartbeat(partyID: "room", deviceID: "device")
        _ = try await api.leave(partyID: "room", deviceID: "device")
        _ = try await api.end(partyID: "room", deviceID: "device")
        _ = try await api.setHostOnly(partyID: "room", deviceID: "device", enabled: false)
        _ = try await api.removeMember(partyID: "room", deviceID: "device", memberID: "other")
        let clock = try await api.clock()
        let enabled = try await api.enabled()
        XCTAssertEqual(clock, 9_007_199_254_740_993)
        XCTAssertTrue(enabled)
        XCTAssertEqual(requests.map { $0.url!.lastPathComponent }, [
            "watch_party_join", "watch_party_preview", "watch_party_heartbeat", "watch_party_leave",
            "watch_party_end", "watch_party_set_host_only", "watch_party_remove_member",
            "watch_party_clock", "watch_party_enabled"
        ])
        XCTAssertEqual(try object(requests[0])["p_code"] as? String, "ABC234")
        XCTAssertEqual(Set(try object(requests[1]).keys), ["p_code"])
        XCTAssertEqual(try object(requests[5])["p_host_only"] as? Bool, false)
        XCTAssertEqual(try object(requests[6])["p_member_id"] as? String, "other")
        XCTAssertTrue(try object(requests[7]).isEmpty)
        XCTAssertTrue(try object(requests[8]).isEmpty)
    }

    func testContextChangedDuringSessionLookupPreventsNetworkRequest() async {
        var current = true
        var sends = 0
        let api = WatchPartyAPI(configuration: configuration(), context: context(), sessionProvider: {
            current = false
            return self.session()
        }, isCurrent: { _ in current }, transport: { request in
            sends += 1
            return self.response(request)
        })
        do { _ = try await api.enabled(); XCTFail("Expected stale context") }
        catch { XCTAssertEqual(error as? WatchPartyAPIError, .staleContext) }
        XCTAssertEqual(sends, 0)
    }

    func testResponseFromPreviousProfileOrMembershipEpochIsDiscarded() async {
        let captured = context()
        var active = captured
        let api = WatchPartyAPI(configuration: configuration(), context: captured, sessionProvider: { self.session() },
                                isCurrent: { $0 == active }, transport: { request in
            active = WatchPartyRequestContext(backendIdentity: self.backend, userID: "user", profileID: "other", epoch: UUID())
            return self.response(request, body: "true")
        })
        do { _ = try await api.enabled(); XCTFail("Expected stale response to be discarded") }
        catch { XCTAssertEqual(error as? WatchPartyAPIError, .staleContext) }
    }

    func testWrongAccountOrBackendNeverSendsCredentials() async {
        for wrongUser in [false, true] {
            var sends = 0
            var supplied = session()
            if wrongUser { supplied.userId = "other" } else { supplied.backendIdentity = "https://other.example.test" }
            let api = WatchPartyAPI(configuration: configuration(), context: context(), sessionProvider: { supplied },
                                    isCurrent: { _ in true }, transport: { request in
                sends += 1
                return self.response(request, body: "true")
            })
            do { _ = try await api.enabled(); XCTFail("Expected sign-in requirement") }
            catch { XCTAssertEqual(error as? WatchPartyAPIError, .signInRequired) }
            XCTAssertEqual(sends, 0)
        }
    }

    func testLegacySessionWithoutBackendIsAcceptedOnlyForOfficialServer() async throws {
        for url in [backend, ServerDiscoveryPolicy.officialBackend] {
            var sends = 0
            var legacy = session()
            legacy.backendIdentity = nil
            let api = WatchPartyAPI(configuration: configuration(url), context: context(url), sessionProvider: { legacy },
                                    isCurrent: { _ in true }, transport: { request in
                sends += 1
                return self.response(request, body: "true")
            })
            if url == backend {
                do { _ = try await api.enabled(); XCTFail("Expected sign-in requirement") }
                catch { XCTAssertEqual(error as? WatchPartyAPIError, .signInRequired) }
                XCTAssertEqual(sends, 0)
            } else {
                let enabled = try await api.enabled()
                XCTAssertTrue(enabled)
                XCTAssertEqual(sends, 1)
            }
        }
    }

    func testInvalidConfigurationAndCodeFailBeforeSessionLookup() async {
        var lookups = 0
        let invalid = "https://party.example.test/?secret=value"
        let api = WatchPartyAPI(configuration: configuration(invalid), context: context(invalid), sessionProvider: {
            lookups += 1
            return self.session()
        }, isCurrent: { _ in true }, transport: { _ in XCTFail("Unexpected transport"); throw URLError(.badURL) })
        do { _ = try await api.enabled(); XCTFail("Expected invalid configuration") }
        catch { XCTAssertEqual(error as? WatchPartyAPIError, .invalidConfiguration) }
        do { _ = try await api.preview(code: "ABC2345"); XCTFail("Expected invalid code") }
        catch { XCTAssertEqual(error as? WatchPartyAPIError, .invalidCode) }
        XCTAssertEqual(lookups, 0)
    }

    func testHTTPFailureIsNotRetriedAndBusinessFailureIsPreserved() async throws {
        for status in [401, 500] {
            var sends = 0
            let api = WatchPartyAPI(configuration: configuration(), context: context(), sessionProvider: { self.session() },
                                    isCurrent: { _ in true }, transport: { request in
                sends += 1
                return self.response(request, status: status)
            })
            do { _ = try await api.create(identity: identity, media: media); XCTFail("Expected HTTP failure") }
            catch { XCTAssertEqual(error as? WatchPartyAPIError, .httpStatus(status)) }
            XCTAssertEqual(sends, 1)
        }
        let api = WatchPartyAPI(configuration: configuration(), context: context(), sessionProvider: { self.session() },
                                isCurrent: { _ in true }, transport: { self.response($0, body: #"{"error":"party_full"}"#) })
        let snapshot = try await api.join(code: "ABC234", identity: identity)
        XCTAssertEqual(snapshot.error, "party_full")
    }

    func testTransportAndMalformedResponseAreSanitized() async {
        for malformedResponse in [false, true] {
            let api = WatchPartyAPI(configuration: configuration(), context: context(), sessionProvider: { self.session() },
                                    isCurrent: { _ in true }, transport: { request in
                if malformedResponse { return self.response(request, body: "private response text") }
                throw NSError(domain: "private transport text", code: 1)
            })
            do { _ = try await api.enabled(); XCTFail("Expected sanitized failure") }
            catch { XCTAssertEqual(error as? WatchPartyAPIError, malformedResponse ? .invalidResponse : .transport) }
        }
    }

    func testTransportCancellationRemainsCancellation() async {
        let api = WatchPartyAPI(configuration: configuration(), context: context(), sessionProvider: { self.session() },
                                isCurrent: { _ in true }, transport: { _ in throw URLError(.cancelled) })
        do { _ = try await api.enabled(); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
