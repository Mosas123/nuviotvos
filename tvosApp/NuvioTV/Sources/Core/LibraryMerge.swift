import Foundation

/// Combines the other libraries for Show all libraries without repeating a
/// title. A title already in the selected library, or already taken from an
/// earlier source, is left out. Two entries are the same title when they share
/// any id (Nuvio, IMDb, TMDB) or the same name and year, so a movie saved in
/// Trakt under its IMDb id and in Simkl under its TMDB id shows once.
enum LibraryMerge {
    struct Entry: Equatable {
        let meta: StremioMeta
        let label: String
    }

    static func others(
        _ sources: [(label: String, items: [LibraryStoreItem])],
        excluding selected: [StremioMeta]
    ) -> [Entry] {
        var seen = Set(selected.flatMap(keys(for:)))
        var result: [Entry] = []
        for source in sources {
            for item in source.items {
                let itemKeys = keys(for: item.meta)
                guard seen.isDisjoint(with: itemKeys) else {
                    seen.formUnion(itemKeys)
                    continue
                }
                seen.formUnion(itemKeys)
                result.append(Entry(meta: item.stremioMeta, label: source.label))
            }
        }
        return result
    }

    static func keys(for meta: NuvioMeta) -> Set<String> {
        var result: Set<String> = ["id:\(meta.id)"]
        if let imdb = meta.imdbId, !imdb.isEmpty { result.insert("id:\(imdb)") }
        if let tmdb = meta.tmdbId, tmdb > 0 { result.insert("id:tmdb:\(tmdb)") }
        if let name = nameKey(meta.name, year: meta.year) { result.insert(name) }
        return result
    }

    static func keys(for meta: StremioMeta) -> Set<String> {
        var result: Set<String> = ["id:\(meta.id)"]
        if let name = nameKey(meta.name, year: meta.year.map(Int.init)) { result.insert(name) }
        return result
    }

    private static func nameKey(_ name: String, year: Int?) -> String? {
        let normalized = name.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !normalized.isEmpty, let year else { return nil }
        return "name:\(normalized):\(year)"
    }
}
