import Foundation
import GRDB

protocol RepositoryMetadataStoring: Sendable {
    func favorites() async throws -> [FavoriteRepositoryItem]
    func favorite(profileID: UUID, url: URL) async throws -> FavoriteRepositoryItem?
    func upsertFavorite(_ favorite: FavoriteRepositoryItem) async throws
    func removeFavorite(id: UUID) async throws
    func setFavoriteAvailability(id: UUID, isAvailable: Bool, revision: Int?) async throws
    func markFavoritesUnavailable(profileID: UUID, atOrBelow url: URL) async throws
    func recentItems(limit: Int) async throws -> [RecentRepositoryItem]
    func recordRecent(_ item: RecentRepositoryItem, maximumCount: Int) async throws
    func clearRecentItems() async throws
    func replaceSearchIndex(profileID: UUID, rootURL: URL, entries: [SearchIndexEntry], indexedAt: Date) async throws
    func searchIndex(profileID: UUID, rootURL: URL, directoryURL: URL?, query: String) async throws -> RepositorySearchResults
    func movePaths(profileID: UUID, from sourceURL: URL, to destinationURL: URL) async throws
    func deleteMetadata(profileID: UUID) async throws
}

actor RepositoryMetadataStore: RepositoryMetadataStoring {
    private let databaseQueue: DatabaseQueue

    init(databaseURL: URL) throws {
        databaseQueue = try DatabaseQueue(path: databaseURL.path)
        try Self.migrator.migrate(databaseQueue)
    }

    init(inMemory: Void = ()) throws {
        databaseQueue = try DatabaseQueue()
        try Self.migrator.migrate(databaseQueue)
    }

    func favorites() throws -> [FavoriteRepositoryItem] {
        try databaseQueue.read { database in
            try FavoriteRecord
                .order(Column("updatedAt").desc)
                .fetchAll(database)
                .map(FavoriteRepositoryItem.init(record:))
        }
    }

    func favorite(profileID: UUID, url: URL) throws -> FavoriteRepositoryItem? {
        try databaseQueue.read { database in
            try FavoriteRecord
                .filter(Column("profileID") == profileID.uuidString && Column("url") == url.absoluteString)
                .fetchOne(database)
                .map(FavoriteRepositoryItem.init(record:))
        }
    }

    func upsertFavorite(_ favorite: FavoriteRepositoryItem) throws {
        try databaseQueue.write { database in
            if let existing = try FavoriteRecord
                .filter(Column("profileID") == favorite.profileID.uuidString && Column("url") == favorite.url.absoluteString)
                .fetchOne(database) {
                var updated = FavoriteRecord(favorite: favorite)
                updated.id = existing.id
                updated.createdAt = existing.createdAt
                try updated.save(database)
            } else {
                var record = FavoriteRecord(favorite: favorite)
                try record.insert(database)
            }
        }
    }

    func removeFavorite(id: UUID) throws {
        try databaseQueue.write { database in
            _ = try FavoriteRecord.deleteOne(database, key: id.uuidString)
        }
    }

    func setFavoriteAvailability(id: UUID, isAvailable: Bool, revision: Int?) throws {
        try databaseQueue.write { database in
            guard var record = try FavoriteRecord.fetchOne(database, key: id.uuidString) else { return }
            record.isAvailable = isAvailable
            if let revision { record.lastKnownRevision = revision }
            record.updatedAt = .now
            try record.update(database)
        }
    }

    func markFavoritesUnavailable(profileID: UUID, atOrBelow url: URL) throws {
        try databaseQueue.write { database in
            let value = url.absoluteString
            let prefix = Self.directoryPrefix(url)
            var favorites = try FavoriteRecord.filter(Column("profileID") == profileID.uuidString).fetchAll(database)
            for index in favorites.indices where favorites[index].url == value || favorites[index].url.hasPrefix(prefix) {
                favorites[index].isAvailable = false
                favorites[index].updatedAt = .now
                try favorites[index].update(database)
            }
        }
    }

    func recentItems(limit: Int = 50) throws -> [RecentRepositoryItem] {
        try databaseQueue.read { database in
            try RecentRecord
                .order(Column("visitedAt").desc)
                .limit(max(0, limit))
                .fetchAll(database)
                .map(RecentRepositoryItem.init(record:))
        }
    }

    func recordRecent(_ item: RecentRepositoryItem, maximumCount: Int = 50) throws {
        try databaseQueue.write { database in
            if let existing = try RecentRecord
                .filter(Column("profileID") == item.profileID.uuidString && Column("url") == item.url.absoluteString)
                .fetchOne(database) {
                var updated = RecentRecord(item: item)
                updated.id = existing.id
                try updated.save(database)
            } else {
                var record = RecentRecord(item: item)
                try record.insert(database)
            }
            let retainedIDs = try String.fetchAll(
                database,
                sql: "SELECT id FROM recentItems ORDER BY visitedAt DESC LIMIT ?",
                arguments: [max(0, maximumCount)]
            )
            if retainedIDs.isEmpty {
                _ = try RecentRecord.deleteAll(database)
            } else {
                _ = try RecentRecord
                    .filter(!retainedIDs.contains(Column("id")))
                    .deleteAll(database)
            }
        }
    }

    func clearRecentItems() throws {
        try databaseQueue.write { database in
            _ = try RecentRecord.deleteAll(database)
        }
    }

    func replaceSearchIndex(
        profileID: UUID,
        rootURL: URL,
        entries: [SearchIndexEntry],
        indexedAt: Date
    ) throws {
        try databaseQueue.write { database in
            _ = try SearchIndexRecord
                .filter(Column("profileID") == profileID.uuidString && Column("rootURL") == rootURL.absoluteString)
                .deleteAll(database)
            for entry in entries {
                var record = SearchIndexRecord(entry: entry)
                try record.insert(database)
            }
            try SearchIndexStateRecord(
                profileID: profileID.uuidString,
                rootURL: rootURL.absoluteString,
                indexedAt: indexedAt
            ).save(database)
        }
    }

    func searchIndex(
        profileID: UUID,
        rootURL: URL,
        directoryURL: URL?,
        query: String
    ) throws -> RepositorySearchResults {
        try databaseQueue.read { database in
            let records = try SearchIndexRecord
                .filter(Column("profileID") == profileID.uuidString && Column("rootURL") == rootURL.absoluteString)
                .fetchAll(database)
            let directoryPrefix = directoryURL.map(Self.directoryPrefix)
            let entries = try records
                .map(SearchIndexEntry.init(record:))
                .filter { entry in
                    let isInDirectory = directoryPrefix.map { entry.url.absoluteString.hasPrefix($0) } ?? true
                    return isInDirectory && entry.name.localizedCaseInsensitiveContains(query)
                }
                .sorted {
                    if $0.kind != $1.kind { return $0.kind == .directory }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            let indexedAt = try SearchIndexStateRecord.fetchOne(
                database,
                key: ["profileID": profileID.uuidString, "rootURL": rootURL.absoluteString]
            )?.indexedAt
            return RepositorySearchResults(entries: entries, indexedAt: indexedAt)
        }
    }

    func movePaths(profileID: UUID, from sourceURL: URL, to destinationURL: URL) throws {
        try databaseQueue.write { database in
            let source = sourceURL.absoluteString
            let sourcePrefix = Self.directoryPrefix(sourceURL)
            let destination = destinationURL.absoluteString
            let destinationPrefix = Self.directoryPrefix(destinationURL)

            var favorites = try FavoriteRecord.filter(Column("profileID") == profileID.uuidString).fetchAll(database)
            for index in favorites.indices where favorites[index].url == source || favorites[index].url.hasPrefix(sourcePrefix) {
                favorites[index].url = Self.replacingPrefix(
                    favorites[index].url,
                    source: source,
                    sourcePrefix: sourcePrefix,
                    destination: destination,
                    destinationPrefix: destinationPrefix
                )
                favorites[index].name = URL(string: favorites[index].url)?.lastPathComponent.removingPercentEncoding ?? favorites[index].name
                favorites[index].updatedAt = .now
                try favorites[index].update(database)
            }

            var recents = try RecentRecord.filter(Column("profileID") == profileID.uuidString).fetchAll(database)
            for index in recents.indices where recents[index].url == source || recents[index].url.hasPrefix(sourcePrefix) {
                recents[index].url = Self.replacingPrefix(
                    recents[index].url,
                    source: source,
                    sourcePrefix: sourcePrefix,
                    destination: destination,
                    destinationPrefix: destinationPrefix
                )
                recents[index].name = URL(string: recents[index].url)?.lastPathComponent.removingPercentEncoding ?? recents[index].name
                try recents[index].update(database)
            }

            let indexed = try SearchIndexRecord.filter(Column("profileID") == profileID.uuidString).fetchAll(database)
            for record in indexed where record.url == source || record.url.hasPrefix(sourcePrefix) {
                let movedURL = Self.replacingPrefix(
                    record.url,
                    source: source,
                    sourcePrefix: sourcePrefix,
                    destination: destination,
                    destinationPrefix: destinationPrefix
                )
                let movedName = URL(string: movedURL)?.lastPathComponent.removingPercentEncoding ?? record.name
                try database.execute(
                    sql: "UPDATE searchIndex SET url = ?, name = ? WHERE profileID = ? AND rootURL = ? AND url = ?",
                    arguments: [movedURL, movedName, record.profileID, record.rootURL, record.url]
                )
            }
        }
    }

    func deleteMetadata(profileID: UUID) throws {
        try databaseQueue.write { database in
            for table in ["favoriteItems", "recentItems", "searchIndex", "searchIndexStates"] {
                try database.execute(sql: "DELETE FROM \(table) WHERE profileID = ?", arguments: [profileID.uuidString])
            }
        }
    }

    private static func directoryPrefix(_ url: URL) -> String {
        url.absoluteString.hasSuffix("/") ? url.absoluteString : url.absoluteString + "/"
    }

    private static func replacingPrefix(
        _ value: String,
        source: String,
        sourcePrefix: String,
        destination: String,
        destinationPrefix: String
    ) -> String {
        if value == source { return destination }
        return destinationPrefix + value.dropFirst(sourcePrefix.count)
    }

    private static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createRepositoryMetadata") { database in
            try database.create(table: "favoriteItems") { table in
                table.column("id", .text).primaryKey()
                table.column("profileID", .text).notNull().indexed()
                table.column("url", .text).notNull()
                table.column("name", .text).notNull()
                table.column("kind", .text).notNull()
                table.column("lastKnownRevision", .integer)
                table.column("isAvailable", .boolean).notNull().defaults(to: true)
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull()
                table.uniqueKey(["profileID", "url"])
            }
            try database.create(table: "recentItems") { table in
                table.column("id", .text).primaryKey()
                table.column("profileID", .text).notNull().indexed()
                table.column("url", .text).notNull()
                table.column("name", .text).notNull()
                table.column("kind", .text).notNull()
                table.column("lastKnownRevision", .integer)
                table.column("visitedAt", .datetime).notNull().indexed()
                table.uniqueKey(["profileID", "url"])
            }
            try database.create(table: "searchIndex") { table in
                table.column("profileID", .text).notNull()
                table.column("rootURL", .text).notNull()
                table.column("url", .text).notNull()
                table.column("name", .text).notNull()
                table.column("kind", .text).notNull()
                table.column("size", .integer)
                table.column("revision", .integer)
                table.column("author", .text)
                table.column("modifiedAt", .datetime)
                table.primaryKey(["profileID", "rootURL", "url"])
            }
            try database.create(index: "searchIndexLookup", on: "searchIndex", columns: ["profileID", "rootURL", "name"])
            try database.create(table: "searchIndexStates") { table in
                table.column("profileID", .text).notNull()
                table.column("rootURL", .text).notNull()
                table.column("indexedAt", .datetime).notNull()
                table.primaryKey(["profileID", "rootURL"])
            }
        }
        return migrator
    }()
}

private struct FavoriteRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "favoriteItems"
    var id: String
    var profileID: String
    var url: String
    var name: String
    var kind: String
    var lastKnownRevision: Int?
    var isAvailable: Bool
    var createdAt: Date
    var updatedAt: Date

    init(favorite: FavoriteRepositoryItem) {
        id = favorite.id.uuidString
        profileID = favorite.profileID.uuidString
        url = favorite.url.absoluteString
        name = favorite.name
        kind = favorite.kind.rawValue
        lastKnownRevision = favorite.lastKnownRevision
        isAvailable = favorite.isAvailable
        createdAt = favorite.createdAt
        updatedAt = favorite.updatedAt
    }
}

private struct RecentRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "recentItems"
    var id: String
    var profileID: String
    var url: String
    var name: String
    var kind: String
    var lastKnownRevision: Int?
    var visitedAt: Date

    init(item: RecentRepositoryItem) {
        id = item.id.uuidString
        profileID = item.profileID.uuidString
        url = item.url.absoluteString
        name = item.name
        kind = item.kind.rawValue
        lastKnownRevision = item.lastKnownRevision
        visitedAt = item.visitedAt
    }
}

private struct SearchIndexRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "searchIndex"
    var profileID: String
    var rootURL: String
    var url: String
    var name: String
    var kind: String
    var size: Int64?
    var revision: Int?
    var author: String?
    var modifiedAt: Date?

    init(entry: SearchIndexEntry) {
        profileID = entry.profileID.uuidString
        rootURL = entry.rootURL.absoluteString
        url = entry.url.absoluteString
        name = entry.name
        kind = entry.kind.rawValue
        size = entry.size
        revision = entry.revision
        author = entry.author
        modifiedAt = entry.modifiedAt
    }
}

private struct SearchIndexStateRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "searchIndexStates"
    let profileID: String
    let rootURL: String
    let indexedAt: Date
}

private extension FavoriteRepositoryItem {
    init(record: FavoriteRecord) throws {
        guard let id = UUID(uuidString: record.id),
              let profileID = UUID(uuidString: record.profileID),
              let url = URL(string: record.url),
              let kind = SavedRepositoryItemKind(rawValue: record.kind) else {
            throw RepositoryMetadataStoreError.invalidRecord
        }
        self.init(
            id: id,
            profileID: profileID,
            url: url,
            name: record.name,
            kind: kind,
            lastKnownRevision: record.lastKnownRevision,
            isAvailable: record.isAvailable,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt
        )
    }
}

private extension RecentRepositoryItem {
    init(record: RecentRecord) throws {
        guard let id = UUID(uuidString: record.id),
              let profileID = UUID(uuidString: record.profileID),
              let url = URL(string: record.url),
              let kind = SavedRepositoryItemKind(rawValue: record.kind) else {
            throw RepositoryMetadataStoreError.invalidRecord
        }
        self.init(
            id: id,
            profileID: profileID,
            url: url,
            name: record.name,
            kind: kind,
            lastKnownRevision: record.lastKnownRevision,
            visitedAt: record.visitedAt
        )
    }
}

private extension SearchIndexEntry {
    init(record: SearchIndexRecord) throws {
        guard let profileID = UUID(uuidString: record.profileID),
              let rootURL = URL(string: record.rootURL),
              let url = URL(string: record.url),
              let kind = SavedRepositoryItemKind(rawValue: record.kind) else {
            throw RepositoryMetadataStoreError.invalidRecord
        }
        self.init(
            profileID: profileID,
            rootURL: rootURL,
            url: url,
            name: record.name,
            kind: kind,
            size: record.size,
            revision: record.revision,
            author: record.author,
            modifiedAt: record.modifiedAt
        )
    }
}

enum RepositoryMetadataStoreError: Error, Equatable, Sendable {
    case invalidRecord
}
