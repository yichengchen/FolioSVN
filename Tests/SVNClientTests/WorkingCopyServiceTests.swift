import Foundation
import XCTest
@testable import SVNClient

final class WorkingCopyServiceTests: XCTestCase {
    func testSnapshotCombinesFilesystemAndSVNStatusWithoutExposingAdministrativeDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkingCopyServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".svn", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("资料", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("未跟踪/.svn", isDirectory: true), withIntermediateDirectories: true)
        try Data("changed".utf8).write(to: root.appendingPathComponent("资料/说明.txt"))
        try Data("new".utf8).write(to: root.appendingPathComponent("新增.txt"))
        try Data("child".utf8).write(to: root.appendingPathComponent("未跟踪/子文件.txt"))
        try Data("nested metadata".utf8).write(to: root.appendingPathComponent("未跟踪/.svn/entries"))
        try Data("metadata".utf8).write(to: root.appendingPathComponent(".svn/entries"))
        defer { try? FileManager.default.removeItem(at: root) }

        let workingCopy = WorkingCopy(
            id: UUID(),
            profileID: UUID(),
            repositoryURL: URL(string: "https://svn.example.com/repo")!,
            localURL: root,
            displayName: "测试工作副本",
            createdAt: .now,
            lastOpenedAt: .now,
            lastKnownRevision: 8
        )
        let client = WorkingCopySnapshotSVNClient(
            info: SVNWorkingCopyInfo(repositoryURL: workingCopy.repositoryURL, localURL: root, revision: 8),
            statuses: [
                SVNWorkingCopyStatusEntry(
                    localURL: root.appendingPathComponent("资料/说明.txt"),
                    relativePath: "资料/说明.txt",
                    state: .modified,
                    revision: 8
                ),
                SVNWorkingCopyStatusEntry(
                    localURL: root.appendingPathComponent("新增.txt"),
                    relativePath: "新增.txt",
                    state: .unversioned,
                    revision: nil
                ),
                SVNWorkingCopyStatusEntry(
                    localURL: root.appendingPathComponent("已删除.txt"),
                    relativePath: "已删除.txt",
                    state: .missing,
                    revision: 8
                ),
                SVNWorkingCopyStatusEntry(
                    localURL: root.appendingPathComponent("未跟踪"),
                    relativePath: "未跟踪",
                    state: .unversioned,
                    revision: nil
                )
            ]
        )
        let service = WorkingCopyService(
            store: try WorkingCopyStore(inMemory: ()),
            profileService: RepositoryProfileService(
                profileStore: try RepositoryProfileStore(inMemory: ()),
                credentialStore: WorkingCopyTestCredentialStore()
            ),
            svnClient: client
        )

        let snapshot = try await service.snapshot(for: workingCopy)
        let entries = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.relativePath, $0) })

        XCTAssertNil(entries[".svn"])
        XCTAssertNil(entries[".svn/entries"])
        XCTAssertNil(entries["未跟踪/.svn"])
        XCTAssertNil(entries["未跟踪/.svn/entries"])
        XCTAssertEqual(entries["资料/说明.txt"]?.status, .modified)
        XCTAssertEqual(entries["新增.txt"]?.status, .unversioned)
        XCTAssertEqual(entries["已删除.txt"]?.status, .missing)
        XCTAssertEqual(entries["已删除.txt"]?.isPresent, false)
        XCTAssertEqual(entries["未跟踪/子文件.txt"]?.status, .unversioned)
        XCTAssertEqual(snapshot.changedItemCount, 5)
    }
}

private struct WorkingCopySnapshotSVNClient: SVNClient {
    let info: SVNWorkingCopyInfo
    let statuses: [SVNWorkingCopyStatusEntry]

    func version() async throws -> String { "1.14.5" }
    func list(url: URL, options: SVNRequestOptions) async throws -> [SVNListEntry] { [] }
    func workingCopyInfo(at localURL: URL) async throws -> SVNWorkingCopyInfo { info }
    func workingCopyStatus(at localURL: URL) async throws -> [SVNWorkingCopyStatusEntry] { statuses }
}

private actor WorkingCopyTestCredentialStore: CredentialStoring {
    func password(for profileID: UUID) async throws -> String? { nil }
    func save(password: String, for profileID: UUID) async throws {}
    func removePassword(for profileID: UUID) async throws {}
}
