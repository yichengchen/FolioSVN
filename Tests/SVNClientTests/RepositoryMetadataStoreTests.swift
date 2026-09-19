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

    func testFavoriteBatchAddAndRemoveAreAppliedTogether() async throws {
        let store = try RepositoryMetadataStore(inMemory: ())
        let profileID = UUID()
        let first = makeFavorite(profileID: profileID, path: "技术部/接口说明.pdf")
        let second = makeFavorite(profileID: profileID, path: "技术部/接入模板.docx")

        try await store.upsertFavorites([first, second])
        let addedFavorites = try await store.favorites()
        XCTAssertEqual(Set(addedFavorites.map(\.url)), Set([first.url, second.url]))

        try await store.removeFavorites(profileID: profileID, urls: [first.url, second.url])
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

    func testRecursiveSearchIndexHydratesDirectoryCachesAndRemovesStaleDescendants() async throws {
        let store = try RepositoryMetadataStore(inMemory: ())
        let profileID = UUID()
        let rootURL = try XCTUnwrap(URL(string: "https://svn.example.com/repo"))
        let directoryURL = rootURL.appendingPathComponent("资料", isDirectory: true)
        let emptyURL = rootURL.appendingPathComponent("空目录", isDirectory: true)
        let staleURL = rootURL.appendingPathComponent("已删除", isDirectory: true)
        try await store.replaceDirectoryCache(profileID: profileID, url: staleURL,
            entries: [SVNListEntry(name: "旧.txt", kind: .file, size: 1, revision: 1, author: nil, updatedAt: nil)],
            cachedAt: .distantPast)
        let indexedAt = Date(timeIntervalSince1970: 2_000)
        let entries = [
            makeIndexEntry(profileID: profileID, rootURL: rootURL, path: "资料", kind: .directory),
            makeIndexEntry(profileID: profileID, rootURL: rootURL, path: "资料/说明.txt"),
            makeIndexEntry(profileID: profileID, rootURL: rootURL, path: "空目录", kind: .directory),
            makeIndexEntry(profileID: profileID, rootURL: rootURL, path: "首页.txt")
        ]

        try await store.replaceSearchIndex(profileID: profileID, rootURL: rootURL,
            entries: entries, indexedAt: indexedAt)

        let loadedRoot = try await store.directoryCache(profileID: profileID, url: rootURL)
        let root = try XCTUnwrap(loadedRoot)
        XCTAssertEqual(root.entries.map(\.name), ["资料", "空目录", "首页.txt"])
        XCTAssertEqual(root.cachedAt, indexedAt)
        let loadedDirectory = try await store.directoryCache(profileID: profileID, url: directoryURL)
        let directory = try XCTUnwrap(loadedDirectory)
        XCTAssertEqual(directory.entries.map(\.name), ["说明.txt"])
        XCTAssertEqual(directory.entries.first?.kind, .file)
        let loadedEmpty = try await store.directoryCache(profileID: profileID, url: emptyURL)
        let empty = try XCTUnwrap(loadedEmpty)
        XCTAssertTrue(empty.entries.isEmpty, "Empty indexed directories must still receive a cache snapshot")
        let loadedStale = try await store.directoryCache(profileID: profileID, url: staleURL)
        XCTAssertNil(loadedStale)
    }

    func testClearingRepositoryCacheRemovesPermissionSensitiveDataButPreservesFavorites() async throws {
        let store = try RepositoryMetadataStore(inMemory: ())
        let profileID = UUID()
        let rootURL = try XCTUnwrap(URL(string: "https://svn.example.com/repo/"))
        let favorite = makeFavorite(profileID: profileID, path: "共享/说明.txt")
        try await store.upsertFavorite(favorite)
        try await store.replaceSearchIndex(
            profileID: profileID,
            rootURL: rootURL,
            entries: [makeIndexEntry(profileID: profileID, rootURL: rootURL, path: "私密/工资.xlsx")],
            indexedAt: .now
        )
        try await store.replaceDirectoryCache(
            profileID: profileID,
            url: rootURL,
            entries: [SVNListEntry(name: "私密", kind: .directory, size: nil, revision: 8, author: nil, updatedAt: nil)],
            cachedAt: .now
        )

        try await store.clearRepositoryCache(profileID: profileID)

        let directoryCache = try await store.directoryCache(profileID: profileID, url: rootURL)
        XCTAssertNil(directoryCache)
        let search = try await store.searchIndex(
            profileID: profileID,
            rootURL: rootURL,
            directoryURL: nil,
            query: "工资"
        )
        XCTAssertTrue(search.entries.isEmpty)
        XCTAssertNil(search.indexedAt)
        let favorites = try await store.favorites()
        XCTAssertEqual(favorites, [favorite])
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

    private func makeIndexEntry(
        profileID: UUID,
        rootURL: URL,
        path: String,
        kind: SavedRepositoryItemKind = .file
    ) -> SearchIndexEntry {
        let components = path.split(separator: "/").map(String.init)
        return SearchIndexEntry(
            profileID: profileID,
            rootURL: rootURL,
            url: components.enumerated().reduce(rootURL) { partial, pair in
                partial.appendingPathComponent(pair.element,
                    isDirectory: pair.offset < components.count - 1 || kind == .directory)
            },
            name: URL(fileURLWithPath: path).lastPathComponent,
            kind: kind,
            size: 10,
            revision: 4,
            author: "tester",
            modifiedAt: Date(timeIntervalSince1970: 200)
        )
    }
}
