import Foundation
import GRDB

protocol RepositoryProfileStoring: Sendable {
    func list() async throws -> [RepositoryProfile]
    func profile(id: UUID) async throws -> RepositoryProfile?
    func upsert(_ profile: RepositoryProfile) async throws
    func delete(id: UUID) async throws
}

actor RepositoryProfileStore: RepositoryProfileStoring {
    private let databaseQueue: DatabaseQueue

    init(databaseURL: URL) throws {
        databaseQueue = try DatabaseQueue(path: databaseURL.path)
        try Self.migrator.migrate(databaseQueue)
    }

    init(inMemory: Void = ()) throws {
        databaseQueue = try DatabaseQueue()
        try Self.migrator.migrate(databaseQueue)
    }

    static func defaultDatabaseURL(fileManager: FileManager = .default) throws -> URL {
#if DEBUG
        if let overridePath = ProcessInfo.processInfo.environment["SVNCLIENT_DATABASE_PATH"],
           !overridePath.isEmpty {
            let url = URL(fileURLWithPath: overridePath)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            return url
        }
#endif
        let directory = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("SVNClient", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("RepositoryProfiles.sqlite")
    }

    func list() throws -> [RepositoryProfile] {
        try databaseQueue.read { database in
            try RepositoryProfileRecord
                .order(Column("updatedAt").desc, Column("displayName").asc)
                .fetchAll(database)
                .map(RepositoryProfile.init(record:))
        }
    }

    func profile(id: UUID) throws -> RepositoryProfile? {
        try databaseQueue.read { database in
            try RepositoryProfileRecord.fetchOne(database, key: id.uuidString).map(RepositoryProfile.init(record:))
        }
    }

    func upsert(_ profile: RepositoryProfile) throws {
        try databaseQueue.write { database in
            try RepositoryProfileRecord(profile: profile).save(database)
        }
    }

    func delete(id: UUID) throws {
        try databaseQueue.write { database in
            _ = try RepositoryProfileRecord.deleteOne(database, key: id.uuidString)
        }
    }

    private static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createRepositoryProfiles") { database in
            try database.create(table: "repositoryProfiles") { table in
                table.column("id", .text).primaryKey()
                table.column("displayName", .text).notNull()
                table.column("baseURL", .text).notNull()
                table.column("username", .text).notNull()
                table.column("certificatePolicy", .text).notNull()
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("addRepositoryStartPath") { database in
            try database.alter(table: "repositoryProfiles") { table in
                table.add(column: "startPath", .text).notNull().defaults(to: "")
            }
        }
        return migrator
    }()
}

private struct RepositoryProfileRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "repositoryProfiles"

    let id: String
    let displayName: String
    let baseURL: String
    let username: String
    let certificatePolicy: String
    let startPath: String
    let createdAt: Date
    let updatedAt: Date

    init(profile: RepositoryProfile) {
        id = profile.id.uuidString
        displayName = profile.displayName
        baseURL = profile.baseURL.absoluteString
        username = profile.username
        certificatePolicy = profile.certificatePolicy.rawValue
        startPath = profile.startPath
        createdAt = profile.createdAt
        updatedAt = profile.updatedAt
    }
}

private extension RepositoryProfile {
    init(record: RepositoryProfileRecord) throws {
        guard let id = UUID(uuidString: record.id),
              let baseURL = URL(string: record.baseURL),
              let certificatePolicy = CertificatePolicy(rawValue: record.certificatePolicy) else {
            throw RepositoryProfileStoreError.invalidStoredProfile
        }
        self.init(
            id: id,
            displayName: record.displayName,
            baseURL: baseURL,
            username: record.username,
            certificatePolicy: certificatePolicy,
            startPath: record.startPath,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt
        )
    }
}

enum RepositoryProfileStoreError: Error, Equatable, Sendable {
    case invalidStoredProfile
}
