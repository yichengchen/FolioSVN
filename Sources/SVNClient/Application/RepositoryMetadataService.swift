import Foundation

actor RepositoryMetadataService {
    static let maximumRecentItems = 50

    private let store: any RepositoryMetadataStoring

    init(store: any RepositoryMetadataStoring) {
        self.store = store
    }

    func favorites() async throws -> [FavoriteRepositoryItem] {
        try await store.favorites()
    }

    func isFavorite(profileID: UUID, url: URL) async throws -> Bool {
        try await store.favorite(profileID: profileID, url: url) != nil
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

    func setFavoriteAvailability(id: UUID, isAvailable: Bool, revision: Int?) async throws {
        try await store.setFavoriteAvailability(id: id, isAvailable: isAvailable, revision: revision)
    }

    func markFavoritesUnavailable(profileID: UUID, atOrBelow url: URL) async throws {
        try await store.markFavoritesUnavailable(profileID: profileID, atOrBelow: url)
    }

    func recentItems() async throws -> [RecentRepositoryItem] {
        try await store.recentItems(limit: Self.maximumRecentItems)
    }

    func recordRecent(
        profileID: UUID,
        url: URL,
        name: String,
        kind: SavedRepositoryItemKind,
        revision: Int?
    ) async throws {
        try await store.recordRecent(
            RecentRepositoryItem(
                id: UUID(),
                profileID: profileID,
                url: url,
                name: name,
                kind: kind,
                lastKnownRevision: revision,
                visitedAt: .now
            ),
            maximumCount: Self.maximumRecentItems
        )
    }

    func clearRecentItems() async throws {
        try await store.clearRecentItems()
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

    func deleteMetadata(profileID: UUID) async throws {
        try await store.deleteMetadata(profileID: profileID)
    }
}
