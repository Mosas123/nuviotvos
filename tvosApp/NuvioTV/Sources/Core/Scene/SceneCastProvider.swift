import Foundation

protocol SceneCastProviding: Sendable {
    func fetchCast(context: SceneContext) async throws -> [SceneCastCandidate]
    func fetchPersonDetail(personId: Int) async -> ScenePersonDetail?
    func fetchPersonBiography(personId: Int) async -> String?
}

extension SceneCastProviding {
    func fetchPersonDetail(personId: Int) async -> ScenePersonDetail? {
        nil
    }
    
    func fetchPersonBiography(personId: Int) async -> String? {
        await fetchPersonDetail(personId: personId)?.biography
    }
}

final class TmdbSceneCastProvider: SceneCastProviding {
    private let urlSession: URLSession
    private let apiKeyProvider: @Sendable () -> String?
    
    init(
        urlSession: URLSession = .shared,
        apiKeyProvider: @escaping @Sendable () -> String? = { TmdbDetailsService.currentApiKey }
    ) {
        self.urlSession = urlSession
        self.apiKeyProvider = apiKeyProvider
    }
    
    func fetchCast(context: SceneContext) async throws -> [SceneCastCandidate] {
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            print("[SceneCastProvider] ⚠️ TMDB API Key is missing. Configure it in Settings -> Integrations -> TMDB.")
            return []
        }
        
        guard let tmdbId = await resolveTmdbId(context: context, apiKey: apiKey) else {
            print("[SceneCastProvider] ⚠️ Could not resolve TMDB ID for \"\(context.title)\" (canonicalId: \(context.canonicalId)).")
            return []
        }
        
        print("[SceneCastProvider] Fetching cast for \"\(context.title)\" with TMDB ID \(tmdbId)...")
        if context.mediaType == "movie" {
            let cast = try await fetchMovieCast(tmdbId: tmdbId, apiKey: apiKey)
            print("[SceneCastProvider] Fetched \(cast.count) movie cast candidates for \"\(context.title)\".")
            return cast
        } else {
            let cast = try await fetchTVCast(
                tmdbId: tmdbId,
                season: context.season,
                episode: context.episode,
                apiKey: apiKey
            )
            print("[SceneCastProvider] Fetched \(cast.count) TV cast candidates for \"\(context.title)\" S\(context.season ?? 1)E\(context.episode ?? 1).")
            return cast
        }
    }
    
    private func resolveTmdbId(context: SceneContext, apiKey: String) async -> Int? {
        if let direct = context.tmdbId, direct > 0 {
            return direct
        }
        
        if context.canonicalId.hasPrefix("tmdb:") {
            let stripped = context.canonicalId.dropFirst(5)
            let idPart = stripped.split(separator: ":").first.map(String.init) ?? String(stripped)
            if let parsed = Int(idPart), parsed > 0 {
                return parsed
            }
        }
        
        let imdb = context.imdbId ?? (context.canonicalId.hasPrefix("tt") ? context.canonicalId.split(separator: ":").first.map(String.init) : nil)
        if let imdb, imdb.hasPrefix("tt") {
            // 1. Try Cinemeta fast-path (no API key, 0ms rate limit)
            let media = (context.mediaType == "movie") ? "movie" : "series"
            let cinemetaUrlString = "https://v3-cinemeta.strem.io/meta/\(media)/\(imdb).json"
            if let cinemetaUrl = URL(string: cinemetaUrlString),
               let (data, response) = try? await urlSession.data(from: cinemetaUrl),
               let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
               let payload = try? JSONDecoder().decode(CinemetaMetaResponse.self, from: data),
               let moviedbId = payload.meta.moviedbId, moviedbId > 0 {
                print("[SceneCastProvider] Resolved TMDB ID \(moviedbId) via Cinemeta for \(imdb).")
                return moviedbId
            }
            
            // 2. Try TMDB /find/ endpoint
            let urlString = "https://api.themoviedb.org/3/find/\(imdb)?api_key=\(apiKey)&external_source=imdb_id"
            if let url = URL(string: urlString),
               let (data, response) = try? await urlSession.data(from: url),
               let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
               let payload = try? JSONDecoder().decode(TmdbFindPayload.self, from: data) {
                if context.mediaType == "movie", let movie = payload.movieResults?.first {
                    return movie.id
                } else if let tv = payload.tvResults?.first {
                    return tv.id
                } else if let movie = payload.movieResults?.first {
                    return movie.id
                }
            }
        }
        
        // 3. Fallback: Search by title in TMDB if no IMDb or direct TMDB ID (essential for anime catalogs like Kitsu/MAL)
        let cleanTitle = context.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanTitle.isEmpty, let encoded = cleanTitle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            let endpoint = (context.mediaType == "movie") ? "search/movie" : "search/tv"
            let searchUrlString = "https://api.themoviedb.org/3/\(endpoint)?query=\(encoded)&api_key=\(apiKey)&language=en-US"
            if let searchUrl = URL(string: searchUrlString),
               let (data, response) = try? await urlSession.data(from: searchUrl),
               let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
               let payload = try? JSONDecoder().decode(TmdbTitleSearchPayload.self, from: data),
               let firstId = payload.results?.first?.id {
                print("[SceneCastProvider] Resolved TMDB ID \(firstId) via search for \"\(context.title)\".")
                return firstId
            }
        }
        
        return nil
    }
    
    private func fetchMovieCast(tmdbId: Int, apiKey: String) async throws -> [SceneCastCandidate] {
        let urlString = "https://api.themoviedb.org/3/movie/\(tmdbId)/credits?api_key=\(apiKey)&language=en-US"
        guard let url = URL(string: urlString) else { return [] }
        
        let (data, response) = try await urlSession.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return []
        }
        
        let decoded = try JSONDecoder().decode(TmdbCreditsPayload.self, from: data)
        let candidates = mapToCandidates(cast: decoded.cast ?? [], guestStars: [])
        return await enrichWithAdditionalImages(candidates, apiKey: apiKey)
    }
    
    private func fetchTVCast(
        tmdbId: Int,
        season: Int?,
        episode: Int?,
        apiKey: String
    ) async throws -> [SceneCastCandidate] {
        // 1. Prioritize exact episode credits including guest appearances
        if let season, let episode {
            let epUrlString = "https://api.themoviedb.org/3/tv/\(tmdbId)/season/\(season)/episode/\(episode)/credits?api_key=\(apiKey)&language=en-US"
            if let url = URL(string: epUrlString),
               let (data, response) = try? await urlSession.data(from: url),
               let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
               let decoded = try? JSONDecoder().decode(TmdbCreditsPayload.self, from: data) {
                let candidates = mapToCandidates(cast: decoded.cast ?? [], guestStars: decoded.guestStars ?? [])
                if !candidates.isEmpty {
                    return await enrichWithAdditionalImages(candidates, apiKey: apiKey)
                }
            }
        }
        
        // 2. Aggregate series credits (includes full voice cast for anime)
        let aggregateUrlString = "https://api.themoviedb.org/3/tv/\(tmdbId)/aggregate_credits?api_key=\(apiKey)&language=en-US"
        if let url = URL(string: aggregateUrlString),
           let (data, response) = try? await urlSession.data(from: url),
           let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
           let decoded = try? JSONDecoder().decode(TmdbCreditsPayload.self, from: data) {
            let candidates = mapToCandidates(cast: decoded.cast ?? [], guestStars: [])
            if !candidates.isEmpty {
                return await enrichWithAdditionalImages(candidates, apiKey: apiKey)
            }
        }
        
        // 3. Fallback: series credits
        let seriesUrlString = "https://api.themoviedb.org/3/tv/\(tmdbId)/credits?api_key=\(apiKey)&language=en-US"
        guard let url = URL(string: seriesUrlString) else { return [] }
        let (data, response) = try await urlSession.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return []
        }
        let decoded = try JSONDecoder().decode(TmdbCreditsPayload.self, from: data)
        let candidates = mapToCandidates(cast: decoded.cast ?? [], guestStars: [])
        return await enrichWithAdditionalImages(candidates, apiKey: apiKey)
    }
    
    private func enrichWithAdditionalImages(_ candidates: [SceneCastCandidate], apiKey: String) async -> [SceneCastCandidate] {
        var enriched: [SceneCastCandidate] = []
        for candidate in candidates {
            guard let tmdbId = candidate.tmdbId, enriched.count < 10 else {
                enriched.append(candidate)
                continue
            }
            let extras = await fetchAdditionalProfileImages(for: tmdbId, apiKey: apiKey)
            let updated = SceneCastCandidate(
                id: candidate.id,
                name: candidate.name,
                character: candidate.character,
                profileURL: candidate.profileURL,
                additionalImageURLs: extras,
                tmdbId: candidate.tmdbId,
                order: candidate.order
            )
            enriched.append(updated)
        }
        return enriched
    }
    
    private func fetchAdditionalProfileImages(for personId: Int, apiKey: String) async -> [URL] {
        let urlString = "https://api.themoviedb.org/3/person/\(personId)/images?api_key=\(apiKey)"
        guard let url = URL(string: urlString),
               let (data, response) = try? await urlSession.data(from: url),
               let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
               let payload = try? JSONDecoder().decode(TmdbPersonImagesPayload.self, from: data) else {
            return []
        }
        return (payload.profiles ?? []).prefix(4).compactMap { profile in
            guard let path = profile.filePath else { return nil }
            let clean = path.hasPrefix("/") ? String(path.dropFirst()) : path
            return URL(string: "https://image.tmdb.org/t/p/w500/\(clean)")
        }
    }
    
    private func mapToCandidates(cast: [TmdbCastItemPayload], guestStars: [TmdbCastItemPayload]) -> [SceneCastCandidate] {
        var seen = Set<Int>()
        var candidates: [SceneCastCandidate] = []
        
        // Main cast first (sorted by billing order), followed by guest stars
        let sortedCast = cast.sorted { ($0.order ?? 999) < ($1.order ?? 999) }
        let sortedGuests = guestStars.sorted { ($0.order ?? 999) < ($1.order ?? 999) }
        let combined = sortedCast + sortedGuests
        for item in combined {
            guard let id = item.id, seen.insert(id).inserted else { continue }
            guard let name = item.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            
            let profileURL = item.profilePath.flatMap { path -> URL? in
                let clean = path.hasPrefix("/") ? String(path.dropFirst()) : path
                return URL(string: "https://image.tmdb.org/t/p/w500/\(clean)")
            }
            
            candidates.append(
                SceneCastCandidate(
                    id: String(id),
                    name: name,
                    character: item.resolvedCharacter?.trimmingCharacters(in: .whitespacesAndNewlines),
                    profileURL: profileURL,
                    tmdbId: id,
                    order: item.order ?? candidates.count
                )
            )
        }
        
        return candidates
    }
    
    private nonisolated(unsafe) static let idCache = NSCache<NSNumber, ScenePersonDetailCacheBox>()
    private nonisolated(unsafe) static let nameCache = NSCache<NSString, ScenePersonDetailCacheBox>()
    
    func fetchPersonDetail(personId: Int) async -> ScenePersonDetail? {
        if let cached = Self.idCache.object(forKey: NSNumber(value: personId)) {
            return cached.detail
        }
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else { return nil }
        let urlString = "https://api.themoviedb.org/3/person/\(personId)?api_key=\(apiKey)&append_to_response=combined_credits&language=en-US"
        guard let url = URL(string: urlString),
              let (data, response) = try? await urlSession.data(from: url),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let payload = try? JSONDecoder().decode(TmdbPersonFullPayload.self, from: data) else {
            return nil
        }
        
        let profileURL = payload.profilePath.flatMap { path -> URL? in
            let clean = path.hasPrefix("/") ? String(path.dropFirst()) : path
            return URL(string: "https://image.tmdb.org/t/p/h632/\(clean)")
        }
        
        var seenMovieIds = Set<Int>()
        var seenSeriesIds = Set<Int>()
        var movies: [ScenePersonMediaCredit] = []
        var series: [ScenePersonMediaCredit] = []
        
        // Sort all credits by popularity descending
        let allCredits = (payload.combinedCredits?.cast ?? []).sorted { ($0.popularity ?? 0) > ($1.popularity ?? 0) }
        
        for item in allCredits {
            let isTv = item.mediaType == "tv"
            let isMovie = item.mediaType == "movie" || (!isTv && item.title != nil)
            let title = (isTv ? item.name : item.title) ?? item.title ?? item.name ?? ""
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            
            let posterURL = item.posterPath.flatMap { path -> URL? in
                let clean = path.hasPrefix("/") ? String(path.dropFirst()) : path
                return URL(string: "https://image.tmdb.org/t/p/w500/\(clean)")
            }
            
            let backdropURL = item.backdropPath.flatMap { path -> URL? in
                let clean = path.hasPrefix("/") ? String(path.dropFirst()) : path
                return URL(string: "https://image.tmdb.org/t/p/w1280/\(clean)")
            }
            
            let year: String?
            if isTv {
                year = item.firstAirDate.flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil }
            } else {
                year = item.releaseDate.flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil }
            }
            
            let credit = ScenePersonMediaCredit(
                id: "\(isTv ? "tv" : "movie")-\(item.id)",
                tmdbId: item.id,
                title: title,
                mediaType: isTv ? "tv" : "movie",
                posterURL: posterURL,
                backdropURL: backdropURL,
                character: item.character?.trimmingCharacters(in: .whitespacesAndNewlines),
                releaseYear: year,
                voteAverage: item.voteAverage
            )
            
            if isTv {
                if seenSeriesIds.insert(item.id).inserted {
                    series.append(credit)
                }
            } else if isMovie {
                if seenMovieIds.insert(item.id).inserted {
                    movies.append(credit)
                }
            }
        }
        
        let result = ScenePersonDetail(
            id: payload.id,
            name: payload.name ?? "",
            biography: payload.biography?.trimmingCharacters(in: .whitespacesAndNewlines),
            birthday: payload.birthday,
            deathday: payload.deathday,
            placeOfBirth: payload.placeOfBirth?.trimmingCharacters(in: .whitespacesAndNewlines),
            profileURL: profileURL,
            movies: movies,
            series: series
        )
        Self.idCache.setObject(ScenePersonDetailCacheBox(detail: result), forKey: NSNumber(value: payload.id))
        return result
    }
    
    func fetchPersonDetail(for person: TmdbPersonMetadata) async -> ScenePersonDetail? {
        if let tmdbId = person.tmdbId, tmdbId > 0 {
            return await fetchPersonDetail(personId: tmdbId)
        }
        let cleanName = person.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanName.isEmpty, cleanName != "cast" else { return nil }
        if let cached = Self.nameCache.object(forKey: cleanName as NSString) {
            return cached.detail
        }
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else { return nil }
        guard let encodedName = person.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        let urlString = "https://api.themoviedb.org/3/search/person?query=\(encodedName)&api_key=\(apiKey)&language=en-US"
        guard let url = URL(string: urlString),
              let (data, response) = try? await urlSession.data(from: url),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let searchResult = try? JSONDecoder().decode(TmdbPersonSearchPayload.self, from: data),
              let firstId = searchResult.results?.first?.id else {
            return nil
        }
        let detail = await fetchPersonDetail(personId: firstId)
        if let detail {
            Self.nameCache.setObject(ScenePersonDetailCacheBox(detail: detail), forKey: cleanName as NSString)
        }
        return detail
    }
    
    func fetchPersonBiography(personId: Int) async -> String? {
        await fetchPersonDetail(personId: personId)?.biography
    }
}

private final class ScenePersonDetailCacheBox: @unchecked Sendable {
    let detail: ScenePersonDetail
    init(detail: ScenePersonDetail) {
        self.detail = detail
    }
}

// MARK: - Internal DTOs

private struct TmdbPersonFullPayload: Decodable {
    let id: Int
    let name: String?
    let biography: String?
    let birthday: String?
    let deathday: String?
    let placeOfBirth: String?
    let profilePath: String?
    let combinedCredits: TmdbCombinedCreditsPayload?

    enum CodingKeys: String, CodingKey {
        case id, name, biography, birthday, deathday
        case placeOfBirth = "place_of_birth"
        case profilePath = "profile_path"
        case combinedCredits = "combined_credits"
    }
}

private struct TmdbCombinedCreditsPayload: Decodable {
    let cast: [TmdbCombinedCreditCastItemPayload]?
}

private struct TmdbCombinedCreditCastItemPayload: Decodable {
    let id: Int
    let title: String?
    let name: String?
    let mediaType: String?
    let character: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let firstAirDate: String?
    let voteAverage: Double?
    let popularity: Double?
    let voteCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, name, character, popularity
        case mediaType = "media_type"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case voteAverage = "vote_average"
        case voteCount = "vote_count"
    }
}

private struct TmdbCreditsPayload: Decodable {
    let cast: [TmdbCastItemPayload]?
    let guestStars: [TmdbCastItemPayload]?
    
    enum CodingKeys: String, CodingKey {
        case cast
        case guestStars = "guest_stars"
    }
}

private struct TmdbCastItemPayload: Decodable {
    let id: Int?
    let name: String?
    let character: String?
    let profilePath: String?
    let order: Int?
    let roles: [TmdbRoleItemPayload]?
    
    var resolvedCharacter: String? {
        if let character, !character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return character
        }
        if let roles, let firstRole = roles.first(where: { !($0.character?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }) {
            return firstRole.character
        }
        return nil
    }
    
    enum CodingKeys: String, CodingKey {
        case id, name, character, order, roles
        case profilePath = "profile_path"
    }
}

private struct TmdbRoleItemPayload: Decodable {
    let character: String?
}

private struct TmdbPersonImagesPayload: Decodable {
    let profiles: [TmdbProfileImagePayload]?
}

private struct TmdbProfileImagePayload: Decodable {
    let filePath: String?
    
    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
    }
}

private struct TmdbFindPayload: Decodable {
    let movieResults: [TmdbFindItemPayload]?
    let tvResults: [TmdbFindItemPayload]?
    
    enum CodingKeys: String, CodingKey {
        case movieResults = "movie_results"
        case tvResults = "tv_results"
    }
}

private struct TmdbFindItemPayload: Decodable {
    let id: Int?
}

private struct TmdbPersonSearchPayload: Decodable {
    let results: [TmdbPersonSearchResultPayload]?
}

private struct TmdbPersonSearchResultPayload: Decodable {
    let id: Int?
}

private struct TmdbTitleSearchPayload: Decodable {
    let results: [TmdbTitleSearchResultPayload]?
}

private struct TmdbTitleSearchResultPayload: Decodable {
    let id: Int?
}
