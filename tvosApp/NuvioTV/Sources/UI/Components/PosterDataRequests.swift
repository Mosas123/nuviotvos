import Foundation

/// Shares only concurrent downloads. Decoded image sizes and persistent artwork
/// storage remain the responsibility of their existing caches.
actor PosterDataRequests {
    static let shared = PosterDataRequests()

    private struct Key: Hashable {
        let url: URL
        let revalidate: Bool
    }

    private var inFlight: [Key: Task<Data?, Never>] = [:]

    func request(
        url: URL,
        revalidate: Bool,
        fetcher: @Sendable @escaping () async -> Data?
    ) -> Task<Data?, Never> {
        let key = Key(url: url, revalidate: revalidate)
        if let existing = inFlight[key] { return existing }

        let task = Task {
            let data = await fetcher()
            // No result cache: failures can retry and completed bytes are not
            // retained here. A cancelled consumer does not cancel other users.
            inFlight.removeValue(forKey: key)
            return data
        }
        inFlight[key] = task
        return task
    }
}
