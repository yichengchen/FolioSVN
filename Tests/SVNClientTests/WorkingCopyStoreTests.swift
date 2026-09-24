import Foundation
import XCTest
@testable import SVNClient

final class WorkingCopyStoreTests: XCTestCase {
    func testServiceRenameChangesOnlyTheDisplayName() async throws {
        let store = try WorkingCopyStore(inMemory: ())
        let profileStore = try RepositoryProfileStore(inMemory: ())
        let service = WorkingCopyService(
            store: store,
            profileService: RepositoryProfileService(
                profileStore: profileStore,
                credentialStore: WorkingCopyStoreTestCredentialStore()
            ),
            svnClient: WorkingCopyStoreTestSVNClient()
        )
        let original = makeWorkingCopy(
            profileID: UUID(),
            name: "原名称",
            path: "/tmp/rename-working-copy",
            lastOpenedAt: Date(timeIntervalSince1970: 100)
        )
        try await store.upsert(original)

        let renamed = try await service.rename(id: original.id, displayName: "  新名称  ")
        let persisted = try await store.workingCopy(id: original.id)

        XCTAssertEqual(renamed.displayName, "新名称")
        XCTAssertEqual(renamed.localURL, original.localURL)
        XCTAssertEqual(persisted?.displayName, "新名称")
    }

    func testMigrationCanShareTheApplicationDatabaseWithExistingStores() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkingCopyMigrationTests-\(UUID().uuidString)", isDirectory: true)
        let databaseURL = directory.appendingPathComponent("Application.sqlite")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try RepositoryProfileStore(databaseURL: databaseURL)
        _ = try RepositoryMetadataStore(databaseURL: databaseURL)
        _ = try WorkingCopyStore(databaseURL: databaseURL)
    }

    func testPersistsOrdersAndRemovesWorkingCopies() async throws {
        let store = try WorkingCopyStore(inMemory: ())
        let profileID = UUID()
        let older = makeWorkingCopy(
            profileID: profileID,
            name: "旧项目",
            path: "/tmp/old",
            lastOpenedAt: Date(timeIntervalSince1970: 100)
        )
        var newer = makeWorkingCopy(
            profileID: profileID,
            name: "新项目",
            path: "/tmp/new",
            lastOpenedAt: Date(timeIntervalSince1970: 200)
        )

        try await store.upsert(older)
        try await store.upsert(newer)
        let initialList = try await store.list()
        XCTAssertEqual(initialList.map(\.id), [newer.id, older.id])

        newer.displayName = "已重命名"
        newer.lastKnownRevision = 42
        try await store.upsert(newer)
        let updatedWorkingCopy = try await store.workingCopy(id: newer.id)
        XCTAssertEqual(updatedWorkingCopy, newer)

        try await store.delete(id: older.id)
        let remainingWorkingCopies = try await store.list()
        XCTAssertEqual(remainingWorkingCopies, [newer])
    }

    private func makeWorkingCopy(
        profileID: UUID,
        name: String,
        path: String,
        lastOpenedAt: Date
    ) -> WorkingCopy {
        WorkingCopy(
            id: UUID(),
            profileID: profileID,
            repositoryURL: URL(string: "https://svn.example.com/repo/\(name)")!,
            localURL: URL(fileURLWithPath: path, isDirectory: true),
            displayName: name,
            createdAt: Date(timeIntervalSince1970: 50),
            lastOpenedAt: lastOpenedAt,
            lastKnownRevision: 1
        )
    }
}

private struct WorkingCopyStoreTestSVNClient: SVNClient {
    func version() async throws -> String { "1.14.5" }
    func list(url: URL, options: SVNRequestOptions) async throws -> [SVNListEntry] { [] }
}

private actor WorkingCopyStoreTestCredentialStore: CredentialStoring {
    func password(for profileID: UUID) async throws -> String? { nil }
    func save(password: String, for profileID: UUID) async throws {}
    func removePassword(for profileID: UUID) async throws {}
}
