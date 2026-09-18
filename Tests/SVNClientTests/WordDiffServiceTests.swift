import Foundation
import XCTest
@testable import SVNClient

final class WordDiffServiceTests: XCTestCase {
    func testMissingRuntimeGivesActionableError() async throws {
        let service = WordDiffService(executableURL: URL(fileURLWithPath: "/nonexistent/worddiff"))
        do {
            _ = try await service.compare(original: URL(fileURLWithPath: "/a.docx"), revised: URL(fileURLWithPath: "/b.docx"))
            XCTFail("Expected missing runtime error")
        } catch WordDiffError.unavailable {
            // Expected.
        }
    }

    func testSuccessfulResponseReturnsOwnedFiles() async throws {
        let executable = FileManager.default.temporaryDirectory.appendingPathComponent("worddiff-test-\(UUID())")
        try Data().write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: executable) }
        let service = WordDiffService(runner: StubWordDiffRunner(), executableURL: executable)
        let result = try await service.compare(original: URL(fileURLWithPath: "/a.docx"), revised: URL(fileURLWithPath: "/b.docx"))
        defer { try? FileManager.default.removeItem(at: result.directoryURL) }
        XCTAssertEqual(result.revisionCount, 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.documentURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.htmlURL.path))
    }
}

private struct StubWordDiffRunner: SVNCommandRunning {
    func run(executableURL: URL, arguments: [String], environment: [String: String]?, standardInput: Data?) async throws -> SVNProcessOutput {
        let document = URL(fileURLWithPath: arguments[3])
        try Data().write(to: document)
        try Data("<html>test</html>".utf8).write(to: document.deletingPathExtension().appendingPathExtension("html"))
        return SVNProcessOutput(standardOutput: Data("{\"status\":\"success\",\"revisionCount\":5}".utf8), standardError: Data(), exitStatus: 0)
    }
}
