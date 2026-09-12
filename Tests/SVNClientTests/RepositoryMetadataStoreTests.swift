import Foundation
import XCTest
@testable import SVNClient

final class RepositoryMetadataStoreTests: XCTestCase {
    func testFavoritesPersistAvailabilityAndCanBeRemoved() async throws {
        let store = try RepositoryMetadataStore(inMemory: ())
        let profileID = UUID()
        let favorite = makeFavorite(profileID: profileID, path: "技术部/接口说明.pdf")

        try await store.upsertFavorite(favorite)
        let loaded = try await store.favorite(profileID: profileID, url: favorite.url)
        XCTAssertEqual(loaded, favorite)

        try await store.renameFavorite(id: favorite.id, name: "常用接口说明")
        let renamed = try await store.favorite(profileID: profileID, url: favorite.url)
        XCTAssertEqual(renamed?.name, "常用接口说明")
        XCTAssertEqual(renamed?.url, favorite.url)

        try await store.setFavoriteAvailability(id: favorite.id, isAvailable: false, revision: nil)
        let unavailableFavorites = try await store.favorites()
        XCTAssertEqual(unavailableFavorites.first?.isAvailable, false)

        try await store.removeFavorite(id: favorite.id)
        let remainingFavorites = try await store.favorites()
        XCTAssertTrue(remainingFavorites.isEmpty)
    }

    func testSearchIsCaseInsensitiveAndCanLimitToCurrentDirectoryTree() async throws {
        let store = try RepositoryMetadataStore(inMemory: ())
        let profileID = UUID()
        let rootURL = try XCTUnwrap(URL(string: "https://svn.example.com/repo/"))
        let technicalURL = rootURL.appendingPathComponent("技术部", isDirectory: true)
        let indexedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = [
            makeIndexEntry(profileID: profileID, rootURL: rootURL, path: "技术部/API-Guide.txt"),
            makeIndexEntry(profileID: profileID, rootURL: rootURL, path: "市场部/api-plan.txt"),
            makeIndexEntry(profileID: profileID, rootURL: rootURL, path: "技术部/其他.txt")
        ]
        try await store.replaceSearchIndex(
            profileID: profileID,
            rootURL: rootURL,
            entries: entries,
            indexedAt: indexedAt
        )

        let allResults = try await store.searchIndex(
            profileID: profileID,
            rootURL: rootURL,
            directoryURL: nil,
            query: "api"
        )
        XCTAssertEqual(Set(allResults.entries.map(\.name)), ["API-Guide.txt", "api-plan.txt"])
        XCTAssertEqual(allResults.indexedAt, indexedAt)

        let currentResults = try await store.searchIndex(
            profileID: profileID,
            rootURL: rootURL,
            directoryURL: technicalURL,
            query: "API"
        )
        XCTAssertEqual(currentResults.entries.map(\.name), ["API-Guide.txt"])
    }

    func testMoveUpdatesFavoriteAndIndexedDescendantPaths() async throws {
        let store = try RepositoryMetadataStore(inMemory: ())
        let profileID = UUID()
        let rootURL = try XCTUnwrap(URL(string: "https://svn.example.com/repo/"))
        let sourceURL = rootURL.appendingPathComponent("旧目录", isDirectory: true)
        let destinationURL = rootURL.appendingPathComponent("新目录", isDirectory: true)
        let childURL = sourceURL.appendingPathComponent("说明.txt")
        let favorite = FavoriteRepositoryItem(
            id: UUID(), profileID: profileID, url: childURL, name: "常用说明", kind: .file,
            lastKnownRevision: 3, isAvailable: true, createdAt: .now, updatedAt: .now
        )
        try await store.upsertFavorite(favorite)
        try await store.replaceSearchIndex(
            profileID: profileID,
            rootURL: rootURL,
            entries: [makeIndexEntry(profileID: profileID, rootURL: rootURL, path: "旧目录/说明.txt")],
            indexedAt: .now
        )

        try await store.movePaths(profileID: profileID, from: sourceURL, to: destinationURL)

        let movedFavorites = try await store.favorites()
        XCTAssertEqual(
            movedFavorites.first?.url,
            destinationURL.appendingPathComponent("说明.txt")
        )
        XCTAssertEqual(movedFavorites.first?.name, "常用说明")
        let results = try await store.searchIndex(
            profileID: profileID,
            rootURL: rootURL,
            directoryURL: nil,
            query: "说明"
        )
        XCTAssertEqual(results.entries.first?.url, destinationURL.appendingPathComponent("说明.txt"))

        try await store.markFavoritesUnavailable(profileID: profileID, atOrBelow: destinationURL)
        let unavailableFavorites = try await store.favorites()
        XCTAssertEqual(unavailableFavorites.first?.isAvailable, false)
    }

    func testDirectoryCachePersistsOrderReplacesEntriesAndCanBeCleared() async throws {
        let store = try RepositoryMetadataStore(inMemory: ())
        let profileID = UUID()
        let url = try XCTUnwrap(URL(string: "https://svn.example.com/repo/"))
        let cachedAt = Date(timeIntervalSince1970: 500)
        let initialEntries = [
            SVNListEntry(name: "资料", kind: .directory, size: nil, revision: 3, author: "a", updatedAt: nil),
            SVNListEntry(name: "说明.txt", kind: .file, size: 12, revision: 4, author: "b", updatedAt: cachedAt)
        ]

        try await store.replaceDirectoryCache(
            profileID: profileID,
            url: url,
            entries: initialEntries,
            cachedAt: cachedAt
        )
        let initialSnapshot = try await store.directoryCache(profileID: profileID, url: url)
        XCTAssertEqual(initialSnapshot, DirectoryCacheSnapshot(entries: initialEntries, cachedAt: cachedAt))

        let replacement = [SVNListEntry(
            name: "新版.txt", kind: .file, size: 20, revision: 5, author: nil, updatedAt: nil
        )]
        try await store.replaceDirectoryCache(
            profileID: profileID,
            url: url,
            entries: replacement,
            cachedAt: cachedAt.addingTimeInterval(1)
        )
        let replacedSnapshot = try await store.directoryCache(profileID: profileID, url: url)
        XCTAssertEqual(replacedSnapshot?.entries, replacement)

        try await store.clearDirectoryCache(profileID: profileID)
        let clearedSnapshot = try await store.directoryCache(profileID: profileID, url: url)
        XCTAssertNil(clearedSnapshot)
    }

    func testMetadataMigrationsShareTheApplicationDatabaseWithProfileMigrations() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SVNClientMetadataTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        _ = try RepositoryProfileStore(databaseURL: databaseURL)
        let metadata = try RepositoryMetadataStore(databaseURL: databaseURL)

        let favorites = try await metadata.favorites()
        XCTAssertTrue(favorites.isEmpty)
    }

    private func makeFavorite(profileID: UUID, path: String) -> FavoriteRepositoryItem {
        FavoriteRepositoryItem(
            id: UUID(),
            profileID: profileID,
            url: URL(string: "https://svn.example.com/repo/")!.appendingPathComponent(path),
            name: URL(fileURLWithPath: path).lastPathComponent,
            kind: .file,
            lastKnownRevision: 12,
            isAvailable: true,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
    }

    private func makeIndexEntry(profileID: UUID, rootURL: URL, path: String) -> SearchIndexEntry {
        SearchIndexEntry(
            profileID: profileID,
            rootURL: rootURL,
            url: path.split(separator: "/").reduce(rootURL) { $0.appendingPathComponent(String($1)) },
            name: URL(fileURLWithPath: path).lastPathComponent,
            kind: .file,
            size: 10,
            revision: 4,
            author: "tester",
            modifiedAt: Date(timeIntervalSince1970: 200)
        )
    }
}
