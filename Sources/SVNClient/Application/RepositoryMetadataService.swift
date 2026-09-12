import Foundation

struct RepositoryFavoriteCandidate: Equatable, Sendable {
    let url: URL
    let name: String
    let kind: SavedRepositoryItemKind
    let revision: Int?
}

actor RepositoryMetadataService {
    private let store: any RepositoryMetadataStoring

    init(store: any RepositoryMetadataStoring) {
        self.store = store
    }

    func favorites() async throws -> [FavoriteRepositoryItem] {
        try await store.favorites()
    }

    @discardableResult
    func toggleFavorite(
        profileID: UUID,
        url: URL,
        name: String,
        kind: SavedRepositoryItemKind,
        revision: Int?
    ) async throws -> Bool {
        if let existing = try await store.favorite(profileID: profileID, url: url) {
            try await store.removeFavorite(id: existing.id)
            return false
        }
        let now = Date()
        try await store.upsertFavorite(FavoriteRepositoryItem(
            id: UUID(),
            profileID: profileID,
            url: url,
            name: name,
            kind: kind,
            lastKnownRevision: revision,
            isAvailable: true,
            createdAt: now,
            updatedAt: now
        ))
        return true
    }

    func removeFavorite(id: UUID) async throws {
        try await store.removeFavorite(id: id)
    }

    @discardableResult
    func setFavorites(
        profileID: UUID,
        candidates: [RepositoryFavoriteCandidate],
        isFavorite: Bool
    ) async throws -> Int {
        guard !candidates.isEmpty else { return 0 }
        let existing = try await store.favorites().filter { $0.profileID == profileID }
        let existingURLs = Set(existing.map { $0.url.absoluteString })
        if isFavorite {
            let missing = candidates.filter { !existingURLs.contains($0.url.absoluteString) }
            let now = Date()
            try await store.upsertFavorites(missing.map { candidate in
                FavoriteRepositoryItem(
                    id: UUID(),
                    profileID: profileID,
                    url: candidate.url,
                    name: candidate.name,
                    kind: candidate.kind,
                    lastKnownRevision: candidate.revision,
                    isAvailable: true,
                    createdAt: now,
                    updatedAt: now
                )
            })
            return missing.count
        }
        let removable = candidates.filter { existingURLs.contains($0.url.absoluteString) }
        try await store.removeFavorites(profileID: profileID, urls: removable.map(\.url))
        return removable.count
    }

    func renameFavorite(id: UUID, name: String) async throws {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return }
        try await store.renameFavorite(id: id, name: normalizedName)
    }

    func setFavoriteAvailability(id: UUID, isAvailable: Bool, revision: Int?) async throws {
        try await store.setFavoriteAvailability(id: id, isAvailable: isAvailable, revision: revision)
    }

    func markFavoritesUnavailable(profileID: UUID, atOrBelow url: URL) async throws {
        try await store.markFavoritesUnavailable(profileID: profileID, atOrBelow: url)
    }

    func replaceSearchIndex(
        profileID: UUID,
        rootURL: URL,
        entries: [SearchIndexEntry],
        indexedAt: Date = .now
    ) async throws {
        try await store.replaceSearchIndex(profileID: profileID, rootURL: rootURL, entries: entries, indexedAt: indexedAt)
    }

    func search(
        profileID: UUID,
        rootURL: URL,
        directoryURL: URL?,
        query: String
    ) async throws -> RepositorySearchResults {
        try await store.searchIndex(
            profileID: profileID,
            rootURL: rootURL,
            directoryURL: directoryURL,
            query: query
        )
    }

    func movePaths(profileID: UUID, from sourceURL: URL, to destinationURL: URL) async throws {
        try await store.movePaths(profileID: profileID, from: sourceURL, to: destinationURL)
    }

    func directoryCache(profileID: UUID, url: URL) async throws -> DirectoryCacheSnapshot? {
        try await store.directoryCache(profileID: profileID, url: url)
    }

    func replaceDirectoryCache(
        profileID: UUID,
        url: URL,
        entries: [SVNListEntry],
        cachedAt: Date = .now
    ) async throws {
        try await store.replaceDirectoryCache(
            profileID: profileID,
            url: url,
            entries: entries,
            cachedAt: cachedAt
        )
    }

    func clearDirectoryCache(profileID: UUID) async throws {
        try await store.clearDirectoryCache(profileID: profileID)
    }

    func deleteMetadata(profileID: UUID) async throws {
        try await store.deleteMetadata(profileID: profileID)
    }
}
