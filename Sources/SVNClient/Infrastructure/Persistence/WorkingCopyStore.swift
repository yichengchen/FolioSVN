import Foundation
import GRDB

protocol WorkingCopyStoring: Sendable {
    func list() async throws -> [WorkingCopy]
    func workingCopy(id: UUID) async throws -> WorkingCopy?
    func upsert(_ workingCopy: WorkingCopy) async throws
    func delete(id: UUID) async throws
}

actor WorkingCopyStore: WorkingCopyStoring {
    private let databaseQueue: DatabaseQueue

    init(databaseURL: URL) throws {
        databaseQueue = try DatabaseQueue(path: databaseURL.path)
        try Self.migrator.migrate(databaseQueue)
    }

    init(inMemory: Void = ()) throws {
        databaseQueue = try DatabaseQueue()
        try Self.migrator.migrate(databaseQueue)
    }

    func list() throws -> [WorkingCopy] {
        try databaseQueue.read { database in
            try WorkingCopyRecord
                .order(Column("lastOpenedAt").desc, Column("displayName").asc)
                .fetchAll(database)
                .map(WorkingCopy.init(record:))
        }
    }

    func workingCopy(id: UUID) throws -> WorkingCopy? {
        try databaseQueue.read { database in
            try WorkingCopyRecord.fetchOne(database, key: id.uuidString).map(WorkingCopy.init(record:))
        }
    }

    func upsert(_ workingCopy: WorkingCopy) throws {
        try databaseQueue.write { database in
            try WorkingCopyRecord(workingCopy: workingCopy).save(database)
        }
    }

    func delete(id: UUID) throws {
        try databaseQueue.write { database in
            _ = try WorkingCopyRecord.deleteOne(database, key: id.uuidString)
        }
    }

    private static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createWorkingCopies") { database in
            try database.create(table: "workingCopies") { table in
                table.column("id", .text).primaryKey()
                table.column("profileID", .text).notNull().indexed()
                table.column("repositoryURL", .text).notNull()
                table.column("localPath", .text).notNull().unique()
                table.column("displayName", .text).notNull()
                table.column("createdAt", .datetime).notNull()
                table.column("lastOpenedAt", .datetime).notNull()
                table.column("lastKnownRevision", .integer)
            }
        }
        return migrator
    }()
}

private struct WorkingCopyRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "workingCopies"

    let id: String
    let profileID: String
    let repositoryURL: String
    let localPath: String
    let displayName: String
    let createdAt: Date
    let lastOpenedAt: Date
    let lastKnownRevision: Int?

    init(workingCopy: WorkingCopy) {
        id = workingCopy.id.uuidString
        profileID = workingCopy.profileID.uuidString
        repositoryURL = workingCopy.repositoryURL.absoluteString
        localPath = workingCopy.localURL.standardizedFileURL.path
        displayName = workingCopy.displayName
        createdAt = workingCopy.createdAt
        lastOpenedAt = workingCopy.lastOpenedAt
        lastKnownRevision = workingCopy.lastKnownRevision
    }
}

private extension WorkingCopy {
    init(record: WorkingCopyRecord) throws {
        guard let id = UUID(uuidString: record.id),
              let profileID = UUID(uuidString: record.profileID),
              let repositoryURL = URL(string: record.repositoryURL) else {
            throw WorkingCopyStoreError.invalidRecord
        }
        self.init(
            id: id,
            profileID: profileID,
            repositoryURL: repositoryURL,
            localURL: URL(fileURLWithPath: record.localPath, isDirectory: true),
            displayName: record.displayName,
            createdAt: record.createdAt,
            lastOpenedAt: record.lastOpenedAt,
            lastKnownRevision: record.lastKnownRevision
        )
    }
}

enum WorkingCopyStoreError: Error, Equatable, Sendable {
    case invalidRecord
}

