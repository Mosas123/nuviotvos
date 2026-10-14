import Foundation
import Testing
@testable import AetherEngine

@Suite("Subtitle headers stay on their original origin", .serialized, .timeLimit(.minutes(2)))
struct SubtitleRedirectCredentialTests {
    private let headers = ["X-Arbitrary-Subtitle-Secret": "SOURCE-ONLY", "Authorization": "Bearer SOURCE-ONLY"]

    private func request(_ url: URL) -> URLRequest {
        var value = URLRequest(url: url)
        value.cachePolicy = .reloadIgnoringLocalCacheData
        for (field, text) in headers { value.setValue(text, forHTTPHeaderField: field) }
        return value
    }

    @Test("Scheme, host and effective port all define the trusted origin", arguments: [
        ("https://media.example/a.srt", "https://media.example/b.srt", true),
        ("https://media.example/a.srt", "https://media.example:443/b.srt", true),
        ("http://media.example/a.srt", "http://media.example:80/b.srt", true),
        ("https://Media.Example/a.srt", "https://media.example/b.srt", true),
        ("https://media.example/a.srt", "https://other.example/b.srt", false),
        ("https://media.example/a.srt", "https://media.example:8443/b.srt", false),
        ("https://media.example/a.srt", "http://media.example/b.srt", false),
        ("http://media.example/a.srt", "https://media.example/b.srt", false)
    ])
    func originDecision(from: String, to: String, allowed: Bool) throws {
        let original = try #require(URL(string: from))
        let target = try #require(URL(string: to))
        let policy = SubtitleHTTPRedirectDelegate(originalURL: original, suppliedHeaders: headers)
        // Model URLSession removing a known auth header while carrying custom fields.
        var carried = request(target)
        carried.setValue(nil, forHTTPHeaderField: "Authorization")
        let next = policy.redirectRequest(carried)
        #expect((next != nil) == allowed)
        if allowed {
            for (field, text) in headers { #expect(next?.value(forHTTPHeaderField: field) == text) }
        }
    }

    @Test("The decoder's actual download retains arbitrary secrets on a same-origin hop")
    func sameOriginDownload() async throws {
        let origin = try #require(ThrottledOriginServer(totalSize: 16, respond: { _, _, path in
            path == "/start.srt" ? .redirect(to: "/final.srt") : .serve200
        }))
        defer { origin.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(origin.port)/start.srt"))
        let (data, response) = try await SubtitleDecoder.downloadHTTPData(for: request(url), suppliedHeaders: headers)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(data.count == 16)
        #expect(origin.requestLog.count == 2)
        let final = try #require(origin.requestHeaders.last)
        for (field, text) in headers { #expect(final[field.lowercased()] == text) }
    }

    @Test("The decoder stops before sending secrets to another port or host", arguments: ["127.0.0.1", "localhost"])
    func crossOriginDownload(targetHost: String) async throws {
        let target = try #require(ThrottledOriginServer(totalSize: 16, respond: { _, _, _ in .serve200 }))
        let targetPort = target.port
        let source = try #require(ThrottledOriginServer(totalSize: 16, respond: { _, _, _ in
            .redirect(to: "http://\(targetHost):\(targetPort)/final.srt")
        }))
        defer { source.stop(); target.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(source.port)/start.srt"))
        let (_, response) = try await SubtitleDecoder.downloadHTTPData(for: request(url), suppliedHeaders: headers)
        #expect((response as? HTTPURLResponse)?.statusCode == 302)
        #expect(target.requestLog.isEmpty, "no request, even without headers, may reach the rejected target")
        let initial = try #require(source.requestHeaders.first)
        #expect(initial["x-arbitrary-subtitle-secret"] == "SOURCE-ONLY")
    }

    @Test("Header-free subtitles retain cross-origin CDN redirects")
    func unprotectedDownloadStillRedirects() async throws {
        let target = try #require(ThrottledOriginServer(totalSize: 16, respond: { _, _, _ in .serve200 }))
        let targetPort = target.port
        let source = try #require(ThrottledOriginServer(totalSize: 16, respond: { _, _, _ in
            .redirect(to: "http://127.0.0.1:\(targetPort)/final.srt")
        }))
        defer { source.stop(); target.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(source.port)/start.srt"))
        let (_, response) = try await SubtitleDecoder.downloadHTTPData(for: URLRequest(url: url), suppliedHeaders: [:])
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(target.requestLog.count == 1)
    }
}
