import Foundation
import XCTest
@testable import SVNClient

final class SVNExecutableResolverTests: XCTestCase {
    func testResolvesKnownHomebrewLocationEvenWhenPATHIsEmpty() throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/svn") else {
            throw XCTSkip("Homebrew SVN is not installed at the Apple Silicon default location")
        }

        XCTAssertEqual(
            SVNExecutableResolver.resolve(
                bundle: Bundle(for: Self.self),
                environment: ["PATH": ""]
            )?.path,
            "/opt/homebrew/bin/svn"
        )
    }

    func testExplicitDebugOverrideHasHighestPriority() throws {
        let executable = FileManager.default.temporaryDirectory
            .appendingPathComponent("svn-resolver-\(UUID().uuidString)")
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: executable) }

        XCTAssertEqual(
            SVNExecutableResolver.resolve(environment: ["SVNCLIENT_SVN_PATH": executable.path, "PATH": ""])?.path,
            executable.path
        )
    }
}
