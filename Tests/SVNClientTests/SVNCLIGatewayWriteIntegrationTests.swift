import Foundation
import XCTest
@testable import SVNClient

final class SVNCLIGatewayWriteIntegrationTests: XCTestCase {
    func testCompleteV1WriteAndExportWorkflowAgainstLocalRepository() async throws {
        guard SVNExecutableResolver.resolve(command: "svn") != nil,
              SVNExecutableResolver.resolve(command: "svnadmin") != nil else {
            throw XCTSkip("svn and svnadmin are required for the local integration test")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SVNClientTests-\(UUID().uuidString)", isDirectory: true)
        let repositoryPath = root.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try run("svnadmin", ["create", repositoryPath.path])

        let repositoryURL = URL(fileURLWithPath: repositoryPath.path)
        let gateway = SVNCLIGateway()

        let mkdirResult = try await gateway.makeDirectory(
            url: repositoryURL.appendingPathComponent("文档", isDirectory: true),
            message: "创建文档目录",
            options: .anonymous
        )
        XCTAssertEqual(mkdirResult.revision, 1)

        let originalFile = root.appendingPathComponent("说明.txt")
        try Data("第一版".utf8).write(to: originalFile)
        let documentURL = repositoryURL.appendingPathComponent("文档", isDirectory: true)
        let uploadResult = try await gateway.upload(
            files: [originalFile],
            to: documentURL,
            message: "上传说明",
            options: .anonymous
        )
        XCTAssertEqual(uploadResult.revision, 2)

        let recursiveEntries = try await gateway.listRecursively(url: repositoryURL, options: .anonymous)
        XCTAssertEqual(Set(recursiveEntries.map(\.name)), ["文档", "文档/说明.txt"])

        let uploadedURL = documentURL.appendingPathComponent("说明.txt")
        let propertyWorkingCopy = root.appendingPathComponent("property-wc", isDirectory: true)
        try run("svn", ["checkout", documentURL.absoluteString, propertyWorkingCopy.path])
        let propertyFile = propertyWorkingCopy.appendingPathComponent("说明.txt")
        try run("svn", ["propset", "client-classification", "internal", propertyFile.path])
        try run("svn", ["commit", propertyFile.path, "--message", "设置属性"])

        let info = try await gateway.info(url: uploadedURL, options: .anonymous)
        XCTAssertEqual(info.name, "说明.txt")
        XCTAssertEqual(info.kind, .file)
        XCTAssertEqual(info.lastChangedRevision, 3)
        XCTAssertEqual(info.properties["client-classification"], "internal")

        let firstExport = root.appendingPathComponent("first-export.txt")
        try await gateway.export(
            url: uploadedURL,
            to: firstExport,
            revision: info.lastChangedRevision,
            overwrite: false,
            options: .anonymous
        )
        XCTAssertEqual(try String(contentsOf: firstExport, encoding: .utf8), "第一版")

        let replacementFile = root.appendingPathComponent("replacement.txt")
        try Data("第二版".utf8).write(to: replacementFile)
        let replaceResult = try await gateway.replace(
            localFileURL: replacementFile,
            targetURL: uploadedURL,
            expectedRevision: 3,
            message: "替换说明",
            options: .anonymous
        )
        XCTAssertEqual(replaceResult.revision, 4)

        let replacedInfo = try await gateway.info(url: uploadedURL, options: .anonymous)
        XCTAssertEqual(replacedInfo.lastChangedRevision, 4)
        try await gateway.export(
            url: uploadedURL,
            to: firstExport,
            revision: replacedInfo.lastChangedRevision,
            overwrite: true,
            options: .anonymous
        )
        XCTAssertEqual(try String(contentsOf: firstExport, encoding: .utf8), "第二版")

        let history = try await gateway.log(
            url: uploadedURL,
            pegRevision: replacedInfo.revision,
            limit: 100,
            options: .anonymous
        )
        XCTAssertEqual(history.map(\.revision), [4, 3, 2])

        let historicalExport = root.appendingPathComponent("historical-export.txt")
        try await gateway.exportHistoricalVersion(
            url: uploadedURL,
            pegRevision: replacedInfo.revision,
            revision: 2,
            to: historicalExport,
            overwrite: false,
            options: .anonymous
        )
        XCTAssertEqual(try String(contentsOf: historicalExport, encoding: .utf8), "第一版")
        let restoreResult = try await gateway.replace(
            localFileURL: historicalExport,
            targetURL: uploadedURL,
            expectedRevision: try XCTUnwrap(replacedInfo.lastChangedRevision),
            message: "恢复：说明.txt 至 r2",
            options: .anonymous
        )
        XCTAssertEqual(restoreResult.revision, 5)

        let restoredExport = root.appendingPathComponent("restored-export.txt")
        try await gateway.export(
            url: uploadedURL,
            to: restoredExport,
            revision: restoreResult.revision,
            overwrite: false,
            options: .anonymous
        )
        XCTAssertEqual(try String(contentsOf: restoredExport, encoding: .utf8), "第一版")

        let folderExport = root.appendingPathComponent("folder-export", isDirectory: true)
        try await gateway.export(
            url: documentURL,
            to: folderExport,
            revision: nil,
            overwrite: false,
            options: .anonymous
        )
        XCTAssertEqual(
            try String(contentsOf: folderExport.appendingPathComponent("说明.txt"), encoding: .utf8),
            "第一版"
        )

        let renamedURL = documentURL.appendingPathComponent("使用说明.txt")
        let moveResult = try await gateway.move(
            from: uploadedURL,
            to: renamedURL,
            message: "重命名说明",
            options: .anonymous
        )
        XCTAssertEqual(moveResult.revision, 6)
        let renamedHistory = try await gateway.log(
            url: renamedURL,
            pegRevision: try XCTUnwrap(moveResult.revision),
            limit: 100,
            options: .anonymous
        )
        XCTAssertTrue(renamedHistory.contains(where: { $0.revision == 2 }))

        let deleteResult = try await gateway.delete(
            url: renamedURL,
            message: "删除说明",
            options: .anonymous
        )
        XCTAssertEqual(deleteResult.revision, 7)
        let remainingEntries = try await gateway.list(url: documentURL)
        XCTAssertTrue(remainingEntries.isEmpty)
    }

    func testReplaceRejectsStaleExpectedRevision() async throws {
        guard SVNExecutableResolver.resolve(command: "svn") != nil,
              SVNExecutableResolver.resolve(command: "svnadmin") != nil else {
            throw XCTSkip("svn and svnadmin are required for the local integration test")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SVNClientTests-\(UUID().uuidString)", isDirectory: true)
        let repositoryPath = root.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try run("svnadmin", ["create", repositoryPath.path])

        let repositoryURL = URL(fileURLWithPath: repositoryPath.path)
        let gateway = SVNCLIGateway()
        let file = root.appendingPathComponent("冲突.txt")
        try Data("内容".utf8).write(to: file)
        _ = try await gateway.upload(files: [file], to: repositoryURL, message: "上传", options: .anonymous)

        do {
            _ = try await gateway.replace(
                localFileURL: file,
                targetURL: repositoryURL.appendingPathComponent("冲突.txt"),
                expectedRevision: 999,
                message: "不应提交",
                options: .anonymous
            )
            XCTFail("Expected stale revision rejection")
        } catch let error as SVNClientError {
            XCTAssertEqual(error, .remoteChanged)
        }
    }

    func testUploadDirectoryRecursivelyAsOneCommit() async throws {
        guard SVNExecutableResolver.resolve(command: "svn") != nil,
              SVNExecutableResolver.resolve(command: "svnadmin") != nil else {
            throw XCTSkip("svn and svnadmin are required for the local integration test")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SVNClientFolderUploadTests-\(UUID().uuidString)", isDirectory: true)
        let repositoryPath = root.appendingPathComponent("repository", isDirectory: true)
        let sourceFolder = root.appendingPathComponent("项目资料", isDirectory: true)
        let standaloneFile = root.appendingPathComponent("清单.txt")
        let nestedFolder = sourceFolder.appendingPathComponent("设计", isDirectory: true)
        let emptyFolder = sourceFolder.appendingPathComponent("空目录", isDirectory: true)
        let svnMetadataFolder = sourceFolder.appendingPathComponent(".svn", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: svnMetadataFolder, withIntermediateDirectories: true)
        try Data("接口规范".utf8).write(to: nestedFolder.appendingPathComponent("说明.txt"))
        try Data("项目清单".utf8).write(to: standaloneFile)
        try Data("system metadata".utf8).write(to: sourceFolder.appendingPathComponent(".DS_Store"))
        try Data("working copy metadata".utf8).write(to: svnMetadataFolder.appendingPathComponent("wc.db"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try run("svnadmin", ["create", repositoryPath.path])

        let repositoryURL = URL(fileURLWithPath: repositoryPath.path)
        let gateway = SVNCLIGateway()
        let result = try await gateway.upload(
            files: [sourceFolder, standaloneFile],
            to: repositoryURL,
            message: "上传项目资料",
            options: .anonymous
        )

        XCTAssertEqual(result.revision, 1)
        let entries = try await gateway.listRecursively(url: repositoryURL, options: .anonymous)
        XCTAssertEqual(Set(entries.map(\.name)), [
            "项目资料",
            "项目资料/设计",
            "项目资料/设计/说明.txt",
            "项目资料/空目录",
            "清单.txt"
        ])

        let exportedFolder = root.appendingPathComponent("exported", isDirectory: true)
        try await gateway.export(
            url: repositoryURL.appendingPathComponent("项目资料", isDirectory: true),
            to: exportedFolder,
            revision: nil,
            overwrite: false,
            options: .anonymous
        )
        XCTAssertEqual(
            try String(contentsOf: exportedFolder.appendingPathComponent("设计/说明.txt"), encoding: .utf8),
            "接口规范"
        )
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: exportedFolder.appendingPathComponent("空目录").path,
            isDirectory: &isDirectory
        ))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportedFolder.appendingPathComponent(".svn").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportedFolder.appendingPathComponent(".DS_Store").path))
    }

    @discardableResult
    private func run(_ command: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        guard let executableURL = SVNExecutableResolver.resolve(command: command) else {
            throw IntegrationCommandError.missing(command)
        }
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = error.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw IntegrationCommandError.failed(command, String(decoding: stderr, as: UTF8.self))
        }
        return stdout
    }
}

private enum IntegrationCommandError: Error {
    case missing(String)
    case failed(String, String)
}
