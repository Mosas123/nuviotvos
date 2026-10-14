//
//  AddonRatingsService.swift
//  NuvioTV
//
//  External ratings resolution and provider discovery from Stremio add-ons,
//  supporting the 'ratings' resource and 'ratingSources' manifest declarations.
//

import Foundation

/// An external rating source defined in an add-on manifest's `ratingSources` array.
struct AddonRatingSource: Codable, Hashable, Identifiable, Sendable {
    let source: String
    let name: String
    let icon: String?
    let max: Double?

    var id: String { source }

    init(source: String, name: String, icon: String? = nil, max: Double? = nil) {
        self.source = source
        self.name = name
        self.icon = icon
        self.max = max
    }
}

/// Discovered rating source with add-on context and current user settings for the Settings UI.
struct AddonRatingSourceSummary: Identifiable, Equatable {
    let source: String
    let name: String
    let addonName: String
    let manifestIcon: String?
    let userIconOverride: String?
    let max: Double?
    var isEnabled: Bool

    var id: String { source }

    var effectiveIconUrl: String? {
        if let userIconOverride = userIconOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !userIconOverride.isEmpty {
            return userIconOverride
        }
        return manifestIcon
    }

    init(
        source: String,
        name: String,
        addonName: String,
        manifestIcon: String? = nil,
        userIconOverride: String? = nil,
        max: Double? = nil,
        isEnabled: Bool = true
    ) {
        self.source = source
        self.name = name
        self.addonName = addonName
        self.manifestIcon = manifestIcon
        self.userIconOverride = userIconOverride
        self.max = max
        self.isEnabled = isEnabled
    }
}

/// The portion of a Stremio manifest needed for ratings resolution.
struct AddonRatingsManifest: Decodable, Sendable {
    let id: String
    let name: String?
    let types: [String]?
    let idPrefixes: [String]?
    let resources: [AddonRatingsManifestResource]?
    let ratingSources: [AddonRatingSource]?

    var displayName: String? {
        name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    init(
        id: String,
        name: String? = nil,
        types: [String]? = nil,
        idPrefixes: [String]? = nil,
        resources: [AddonRatingsManifestResource]? = nil,
        ratingSources: [AddonRatingSource]? = nil
    ) {
        self.id = id
        self.name = name
        self.types = types
        self.idPrefixes = idPrefixes
        self.resources = resources
        self.ratingSources = ratingSources
    }

    func supportsRatings(type: String, id: String) -> Bool {
        guard let resources, !resources.isEmpty else { return false }
        let fallbackTypes = types ?? []
        let fallbackPrefixes = idPrefixes ?? []
        for resource in resources {
            if resource.name.caseInsensitiveCompare("ratings") == .orderedSame,
               resource.supportsType(type, fallbackTypes: fallbackTypes),
               resource.supportsId(id, fallbackPrefixes: fallbackPrefixes) {
                return true
            }
        }
        return false
    }
}

struct AddonRatingsManifestResource: Decodable, Sendable {
    let name: String
    let types: [String]
    let idPrefixes: [String]?

    enum CodingKeys: String, CodingKey {
        case name, types, idPrefixes
    }

    init(name: String, types: [String] = [], idPrefixes: [String]? = nil) {
        self.name = name
        self.types = types
        self.idPrefixes = idPrefixes
    }

    init(from decoder: Decoder) throws {
        let singleValue = try decoder.singleValueContainer()
        if let value = try? singleValue.decode(String.self) {
            name = value
            types = []
            idPrefixes = nil
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        types = (try? container.decode([String].self, forKey: .types)) ?? []
        idPrefixes = try? container.decode([String].self, forKey: .idPrefixes)
    }

    func supportsType(_ type: String, fallbackTypes: [String]) -> Bool {
        let supportedTypes = types.isEmpty ? fallbackTypes : types
        guard !supportedTypes.isEmpty else { return true }
        if supportedTypes.contains(where: { AddonTransportUrls.isTypeEquivalent($0, type) }) {
            return true
        }
        if CinemetaCatalogRepository.isLiveContentType(type) {
            return supportedTypes.contains(where: { CinemetaCatalogRepository.isLiveContentType($0) })
        }
        return false
    }

    func supportsId(_ id: String, fallbackPrefixes: [String]) -> Bool {
        let prefixes = (idPrefixes?.isEmpty == false) ? (idPrefixes ?? []) : fallbackPrefixes
        guard !prefixes.isEmpty else { return true }
        return prefixes.contains { id.lowercased().hasPrefix($0.lowercased()) }
    }
}

struct AddonRatingsResponse: Decodable {
    let ratings: [AddonRatingItem]?

    init(ratings: [AddonRatingItem]?) {
        self.ratings = ratings
    }
}

struct AddonRatingItem: Decodable {
    let source: String
    let value: Double
    let url: String?

    enum CodingKeys: String, CodingKey {
        case source, value, url
    }

    init(source: String, value: Double, url: String? = nil) {
        self.source = source
        self.value = value
        self.url = url
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(String.self, forKey: .source)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        if let doubleVal = try? container.decode(Double.self, forKey: .value) {
            value = doubleVal
        } else if let stringVal = try? container.decode(String.self, forKey: .value),
                  let doubleVal = Double(stringVal) {
            value = doubleVal
        } else {
            value = 0.0
        }
    }
}

enum AddonRatingsService {
    /// Built-in providers that cannot be spoofed by add-ons.
    static let builtInProviders: Set<String> = [
        "imdb", "tmdb", "tomatoes", "metacritic", "trakt",
        "letterboxd", "audience", "myanimelist", "mal", "tvdb"
    ]

    private static let enabledKeyPrefix = "nuvio.tv.settings.ratings.addon_enabled."
    private static let iconOverrideKeyPrefix = "nuvio.tv.settings.ratings.addon_icon_override."

    static func isSourceEnabled(_ source: String, defaults: UserDefaults = ProfileSettings.current) -> Bool {
        let key = enabledKeyPrefix + source.lowercased()
        return defaults.object(forKey: key) as? Bool ?? true
    }

    static func setSourceEnabled(_ source: String, enabled: Bool, defaults: UserDefaults = ProfileSettings.current) {
        let key = enabledKeyPrefix + source.lowercased()
        defaults.set(enabled, forKey: key)
    }

    static func iconOverride(for source: String, defaults: UserDefaults = ProfileSettings.current) -> String? {
        let key = iconOverrideKeyPrefix + source.lowercased()
        return defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    static func setIconOverride(for source: String, urlString: String?, defaults: UserDefaults = ProfileSettings.current) {
        let key = iconOverrideKeyPrefix + source.lowercased()
        let trimmed = urlString?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let trimmed {
            defaults.set(trimmed, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    static func loadManifestsConcurrently(urls: [URL]) async -> [URL: AddonRatingsManifest] {
        await withTaskGroup(of: (URL, AddonRatingsManifest?).self) { group in
            for url in urls {
                group.addTask {
                    guard let data = await StremioManifestDataCache.shared.data(for: url) else {
                        return (url, nil)
                    }
                    let manifest = try? JSONDecoder().decode(AddonRatingsManifest.self, from: data)
                    return (url, manifest)
                }
            }
            var result: [URL: AddonRatingsManifest] = [:]
            for await (url, manifest) in group {
                if let manifest {
                    result[url] = manifest
                }
            }
            return result
        }
    }

    static func availableRatingSources(
        manifestURLs: [URL]? = nil,
        defaults: UserDefaults = ProfileSettings.current
    ) async -> [AddonRatingSourceSummary] {
        let urls = manifestURLs ?? CinemetaCatalogRepository.configuredStreamAddonManifestURLs(in: defaults)
        let manifests = await loadManifestsConcurrently(urls: urls)
        var summaries: [AddonRatingSourceSummary] = []
        var seenSources = Set<String>()

        for url in urls {
            guard let manifest = manifests[url],
                  let sources = manifest.ratingSources, !sources.isEmpty else { continue }
            let addonName = manifest.displayName ?? CinemetaCatalogRepository.streamAddonName(for: url)
            for source in sources {
                let lower = source.source.lowercased()
                guard !builtInProviders.contains(lower) else { continue }
                guard seenSources.insert(lower).inserted else { continue }
                summaries.append(
                    AddonRatingSourceSummary(
                        source: source.source,
                        name: source.name,
                        addonName: addonName,
                        manifestIcon: source.icon,
                        userIconOverride: iconOverride(for: source.source, defaults: defaults),
                        max: source.max,
                        isEnabled: isSourceEnabled(source.source, defaults: defaults)
                    )
                )
            }
        }
        return summaries
    }

    static func fetchRatings(
        for meta: NuvioMeta,
        manifestURLs: [URL]? = nil,
        session: URLSession = .shared,
        defaults: UserDefaults = ProfileSettings.current
    ) async -> [NuvioExternalRating] {
        let urls = manifestURLs ?? CinemetaCatalogRepository.configuredStreamAddonManifestURLs(in: defaults)
        guard !urls.isEmpty else { return [] }

        let mediaType = meta.isSeries ? "series" : "movie"
        let contentID = meta.id

        let manifests = await loadManifestsConcurrently(urls: urls)
        var eligible: [(url: URL, manifest: AddonRatingsManifest)] = []
        for url in urls {
            guard let manifest = manifests[url],
                  manifest.supportsRatings(type: mediaType, id: contentID) else { continue }
            eligible.append((url, manifest))
        }
        guard !eligible.isEmpty else { return [] }

        return await withTaskGroup(of: [NuvioExternalRating].self) { group in
            for item in eligible {
                group.addTask {
                    await fetchRatingsFromAddon(
                        manifestURL: item.url,
                        manifest: item.manifest,
                        type: mediaType,
                        id: contentID,
                        session: session,
                        defaults: defaults
                    )
                }
            }
            var allRatings: [NuvioExternalRating] = []
            for await ratings in group {
                allRatings.append(contentsOf: ratings)
            }
            return allRatings
        }
    }

    static func fetchRatingsFromAddon(
        manifestURL: URL,
        manifest: AddonRatingsManifest,
        type: String,
        id: String,
        session: URLSession = .shared,
        defaults: UserDefaults = ProfileSettings.current
    ) async -> [NuvioExternalRating] {
        guard let endpointURL = AddonTransportUrls.buildResourceURL(
            manifestURL: manifestURL,
            resource: "ratings",
            type: type,
            id: id
        ) else { return [] }

        var request = URLRequest(url: endpointURL)
        request.timeoutInterval = 8
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return []
            }
            let payload = try JSONDecoder().decode(AddonRatingsResponse.self, from: data)
            guard let items = payload.ratings, !items.isEmpty else { return [] }

            let sourceLookup = Dictionary(
                (manifest.ratingSources ?? []).map { ($0.source.lowercased(), $0) },
                uniquingKeysWith: { first, _ in first }
            )

            var results: [NuvioExternalRating] = []
            for item in items {
                let lower = item.source.lowercased()
                // Anti-spoofing: prevent overriding built-in providers
                guard !builtInProviders.contains(lower) else { continue }
                // User disabled toggle check
                guard isSourceEnabled(item.source, defaults: defaults) else { continue }

                let declared = sourceLookup[lower]
                let displayName = declared?.name ?? item.source
                let manifestIcon = declared?.icon
                let overrideIcon = iconOverride(for: item.source, defaults: defaults)
                let effectiveIcon = (overrideIcon?.isEmpty == false) ? overrideIcon : manifestIcon
                let max = declared?.max

                results.append(
                    NuvioExternalRating(
                        source: item.source,
                        value: item.value,
                        url: item.url,
                        name: displayName,
                        iconUrl: effectiveIcon,
                        max: max
                    )
                )
            }
            return results
        } catch {
            return []
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

