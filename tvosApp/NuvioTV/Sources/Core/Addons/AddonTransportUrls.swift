//
//  AddonTransportUrls.swift
//  NuvioTV
//
//  Canonical Stremio add-on transport and resource URL construction,
//  matching Android AddonTransportUrls.kt.
//

import Foundation

public enum AddonTransportUrls {
    /// Configured URLs may carry credentials in user info, paths, queries, or fragments.
    /// Diagnostics retain only the origin and an error code, never the error's URL-bearing text.
    static func diagnosticDescription(for url: URL, error: Error? = nil) -> String {
        var origin = "<redacted URL>"
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
           components.host != nil {
            components.user = nil
            components.password = nil
            components.path = ""
            components.query = nil
            components.fragment = nil
            origin = components.string ?? origin
        }
        guard let error else { return origin }
        let nsError = error as NSError
        return "\(origin) errorDomain=\(nsError.domain) code=\(nsError.code)"
    }

    /// Extracts the base URL of a manifest (everything before `?` and without trailing `/manifest.json`).
    public static func baseUrl(from manifestURL: URL) -> String {
        let full = manifestURL.absoluteString
        let urlWithoutQuery = full.components(separatedBy: "?").first ?? full
        if urlWithoutQuery.hasSuffix("/manifest.json") {
            return String(urlWithoutQuery.dropLast("/manifest.json".count))
        }
        return urlWithoutQuery
    }

    /// Extracts the query string (`?token=...` or `?apiKey=...`) from a manifest URL if present.
    public static func query(from manifestURL: URL) -> String {
        guard let query = manifestURL.query, !query.isEmpty else { return "" }
        return "?\(query)"
    }

    /// Percent-encodes a path segment (encoding `:`, `/`, spaces, etc.) per the Stremio protocol.
    public static func encodePathSegment(_ segment: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }

    /// Checks if two media types are equivalent (e.g. "series" <-> "tv", "movie" <-> "movies").
    public static func isTypeEquivalent(_ candidate: String, _ target: String) -> Bool {
        if candidate.caseInsensitiveCompare(target) == .orderedSame {
            return true
        }
        let seriesTypes: Set<String> = ["series", "tv", "show", "tvshow", "tv_series", "shows"]
        if seriesTypes.contains(candidate.lowercased()) && seriesTypes.contains(target.lowercased()) {
            return true
        }
        let movieTypes: Set<String> = ["movie", "movies", "film", "films"]
        if movieTypes.contains(candidate.lowercased()) && movieTypes.contains(target.lowercased()) {
            return true
        }
        return false
    }

    /// Builds a Stremio add-on resource URL preserving query parameters and properly encoding the id.
    /// Format: `<base>/<resource>/<type>/<encodedId>.json<query>`
    /// or with extra path segment: `<base>/<resource>/<type>/<encodedId>/<extra>.json<query>`
    public static func buildResourceURL(
        manifestURL: URL,
        resource: String,
        type: String,
        id: String,
        extraPathSegment: String? = nil
    ) -> URL? {
        let base = baseUrl(from: manifestURL)
        let encodedId = encodePathSegment(id)
        let q = query(from: manifestURL)
        let path: String
        if let extra = extraPathSegment, !extra.isEmpty {
            path = "\(base)/\(resource)/\(type)/\(encodedId)/\(extra).json\(q)"
        } else {
            path = "\(base)/\(resource)/\(type)/\(encodedId).json\(q)"
        }
        return URL(string: path)
    }

    /// Builds the `extra` path segment for a Stremio subtitle request:
    /// e.g. `videoHash=<hash>&videoSize=<size>&filename=<filename>`
    public static func buildSubtitleExtraPathSegment(
        videoHash: String? = nil,
        videoSize: Int64? = nil,
        filename: String? = nil
    ) -> String? {
        var parts: [String] = []
        if let videoHash = videoHash?.trimmingCharacters(in: .whitespacesAndNewlines), !videoHash.isEmpty {
            parts.append("videoHash=\(encodePathSegment(videoHash))")
        }
        if let videoSize, videoSize > 0 {
            parts.append("videoSize=\(videoSize)")
        }
        if let filename = filename?.trimmingCharacters(in: .whitespacesAndNewlines), !filename.isEmpty {
            parts.append("filename=\(encodePathSegment(filename))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "&")
    }

    /// Convenience for building a subtitle resource URL with optional videoHash, videoSize, and filename extras.
    public static func buildSubtitleURL(
        manifestURL: URL,
        type: String,
        id: String,
        videoHash: String? = nil,
        videoSize: Int64? = nil,
        filename: String? = nil
    ) -> URL? {
        let extra = buildSubtitleExtraPathSegment(
            videoHash: videoHash,
            videoSize: videoSize,
            filename: filename
        )
        return buildResourceURL(
            manifestURL: manifestURL,
            resource: "subtitles",
            type: type,
            id: id,
            extraPathSegment: extra
        )
    }
}
