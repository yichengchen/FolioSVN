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

        try await store.setFavoriteAvailability(id: favorite.id, isAvailable: false, revision: nil)
        let unavailableFavorites = try await store.favorites()
        XCTAssertEqual(unavailableFavorites.first?.isAvailable, false)

        try await store.removeFavorite(id: favorite.id)
        let remainingFavorites = try await store.favorites()
        XCTAssertTrue(remainingFavorites.isEmpty)
    }

    func testRecentItemsDeduplicateAndKeepNewestFifty() async throws {
        let store = try RepositoryMetadataStore(inMemory: ())
        let profileID = UUID()
        let baseURL = try XCTUnwrap(URL(string: "https://svn.example.com/repo/"))

        for index in 0..<55 {
            try await store.recordRecent(
                RecentRepositoryItem(
                    id: UUID(),
                    profileID: profileID,
                    url: baseURL.appendingPathComponent("文件\(index).txt"),
                    name: "文件\(index).txt",
                    kind: .file,
                    lastKnownRevision: index,
                    visitedAt: Date(timeIntervalSince1970: TimeInterval(index))
                ),
                maximumCount: 50
            )
        }

        var items = try await store.recentItems(limit: 100)
        XCTAssertEqual(items.count, 50)
        XCTAssertEqual(items.first?.name, "文件54.txt")
        XCTAssertNil(items.first(where: { $0.name == "文件0.txt" }))

        let revisited = try XCTUnwrap(items.last)
        try await store.recordRecent(
            RecentRepositoryItem(
                id: UUID(),
                profileID: profileID,
                url: revisited.url,
                name: revisited.name,
                kind: revisited.kind,
                lastKnownRevision: 999,
                visitedAt: Date(timeIntervalSince1970: 1_000)
            ),
            maximumCount: 50
        )
        items = try await store.recentItems(limit: 100)
        XCTAssertEqual(items.count, 50)
        XCTAssertEqual(items.first?.url, revisited.url)
        XCTAssertEqual(items.first?.lastKnownRevision, 999)
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

    func testMoveUpdatesFavoriteRecentAndIndexedDescendantPaths() async throws {
        let store = try RepositoryMetadataStore(inMemory: ())
        let profileID = UUID()
        let rootURL = try XCTUnwrap(URL(string: "https://svn.example.com/repo/"))
        let sourceURL = rootURL.appendingPathComponent("旧目录", isDirectory: true)
        let destinationURL = rootURL.appendingPathComponent("新目录", isDirectory: true)
        let childURL = sourceURL.appendingPathComponent("说明.txt")
        let favorite = FavoriteRepositoryItem(
            id: UUID(), profileID: profileID, url: childURL, name: "说明.txt", kind: .file,
            lastKnownRevision: 3, isAvailable: true, createdAt: .now, updatedAt: .now
        )
        try await store.upsertFavorite(favorite)
        try await store.recordRecent(
            RecentRepositoryItem(
                id: UUID(), profileID: profileID, url: sourceURL, name: "旧目录", kind: .directory,
                lastKnownRevision: 3, visitedAt: .now
            ),
            maximumCount: 50
        )
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
        let movedRecents = try await store.recentItems(limit: 50)
        XCTAssertEqual(movedRecents.first?.url, destinationURL)
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
