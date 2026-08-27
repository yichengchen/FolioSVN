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
            "第二版"
        )

        let renamedURL = documentURL.appendingPathComponent("使用说明.txt")
        let moveResult = try await gateway.move(
            from: uploadedURL,
            to: renamedURL,
            message: "重命名说明",
            options: .anonymous
        )
        XCTAssertEqual(moveResult.revision, 5)

        let deleteResult = try await gateway.delete(
            url: renamedURL,
            message: "删除说明",
            options: .anonymous
        )
        XCTAssertEqual(deleteResult.revision, 6)
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
