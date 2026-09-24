import Foundation
import XCTest
@testable import SVNClient

private func makeMockGateway(_ runner: MockSVNCommandRunner) -> SVNCLIGateway {
    SVNCLIGateway(
        runner: runner,
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        executableName: "svn"
    )
}

final class SVNCLIGatewayTests: XCTestCase {
    func testWorkingCopyStatusMapsKnownAndUnknownSVNValues() {
        let mappings: [(String, WorkingCopyItemStatus?)] = [
            ("normal", nil),
            ("modified", .modified),
            ("added", .added),
            ("unversioned", .unversioned),
            ("deleted", .deleted),
            ("missing", .missing),
            ("replaced", .replaced),
            ("conflicted", .conflicted),
            ("obstructed", .obstructed),
            ("ignored", .ignored),
            ("external", .external),
            ("incomplete", .incomplete),
            ("future-state", .unknown("future-state"))
        ]

        for (rawValue, expected) in mappings {
            XCTAssertEqual(SVNWorkingCopyItemState(svnValue: rawValue).domainStatus, expected)
        }
    }

    func testCheckoutRemovesLandedDirectoryWhenFinalVerificationFails() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("checkout-verification-failure-\(UUID().uuidString)", isDirectory: true)
        let destination = root.appendingPathComponent("working-copy", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gateway = SVNCLIGateway(
            runner: CheckoutVerificationFailureRunner(),
            executableURL: URL(fileURLWithPath: "/bin/true")
        )

        do {
            _ = try await gateway.checkout(
                url: URL(string: "https://svn.example.com/repo")!,
                to: destination,
                options: .anonymous
            )
            XCTFail("Expected final working copy verification to fail")
        } catch SVNClientError.invalidWorkingCopy {
            // Expected.
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testExportWithoutOverwritePreservesFileCreatedDuringDownload() async throws {
        try await assertLateDestinationIsPreserved(isDirectory: false)
    }

    func testExportWithoutOverwritePreservesDirectoryCreatedDuringDownload() async throws {
        try await assertLateDestinationIsPreserved(isDirectory: true)
    }

    private func assertLateDestinationIsPreserved(isDirectory: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("export-race-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("download", isDirectory: isDirectory)
        let gateway = SVNCLIGateway(runner: ExportDestinationRaceRunner(destination: destination, isDirectory: isDirectory),
            executableURL: URL(fileURLWithPath: "/bin/true"))
        do {
            try await gateway.export(url: URL(string: "https://example.com/file")!, to: destination,
                revision: 1, overwrite: false, options: .anonymous)
            XCTFail("Destination created after the initial check must not be overwritten")
        } catch SVNClientError.destinationExists {}
        let contentURL = isDirectory ? destination.appendingPathComponent("content.txt") : destination
        XCTAssertEqual(try String(contentsOf: contentURL, encoding: .utf8), "user-created-content")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["download"], "Partial export must be cleaned")
    }

    func testExportWithOverwriteStillAllowsAuthorizedReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("export-authorized-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("download.txt")
        let gateway = SVNCLIGateway(runner: ExportDestinationRaceRunner(destination: destination, isDirectory: false),
            executableURL: URL(fileURLWithPath: "/bin/true"))
        try await gateway.export(url: URL(string: "https://example.com/file")!, to: destination,
            revision: 1, overwrite: true, options: .anonymous)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "repository-content")
    }

    func testProcessRunnerCancellationDoesNotWaitForChildCommand() async throws {
        let runner = ProcessSVNCommandRunner()
        let task = Task {
            try await runner.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["60"],
                environment: nil,
                standardInput: nil
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        let clock = ContinuousClock()
        let startedCancelling = clock.now

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertLessThan(startedCancelling.duration(to: clock.now), .seconds(2))
    }

    func testUploadCopyStopsBeforeTouchingDestinationWhenTaskIsCancelled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("upload-copy-cancel-\(UUID())")
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("destination.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("content".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: root) }

        let task = Task { () -> Error? in
            while !Task.isCancelled { await Task.yield() }
            do {
                try SVNCLIGateway.copyUploadItem(from: source, to: destination)
                return nil
            } catch {
                return error
            }
        }
        task.cancel()

        let error = await task.value
        XCTAssertTrue(error is CancellationError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testVersionUsesExpectedProcessArguments() async throws {
        let runner = MockSVNCommandRunner(output: .success(stdout: "1.14.5\n"))
        let gateway = makeMockGateway(runner)

        let version = try await gateway.version()

        XCTAssertEqual(version, "1.14.5")
        XCTAssertEqual(runner.calls, [["svn", "--version", "--quiet"]])
    }

    func testBundledRuntimeInjectsItsOwnCABundle() async throws {
        let runtime = FileManager.default.temporaryDirectory
            .appendingPathComponent("svn-runtime-\(UUID().uuidString)")
        let executable = runtime.appendingPathComponent("bin/svn")
        let caBundle = runtime.appendingPathComponent("etc/ssl/cert.pem")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: caBundle.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: caBundle.path, contents: Data("certificate".utf8)))
        defer { try? FileManager.default.removeItem(at: runtime) }

        let runner = MockSVNCommandRunner(output: .success(stdout: "1.14.5\n"))
        let gateway = SVNCLIGateway(runner: runner, executableURL: executable)

        _ = try await gateway.version()

        XCTAssertEqual(runner.invocations.single?.environment?["SSL_CERT_FILE"], caBundle.path)
        XCTAssertNil(runner.invocations.single?.environment?["SSL_CERT_DIR"])
    }

    func testListMapsRealXMLFixtureAndUsesSafeArguments() async throws {
        let fixtureURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "svn-list", withExtension: "xml"))
        let fixture = try Data(contentsOf: fixtureURL)
        let runner = MockSVNCommandRunner(output: .success(stdout: fixture))
        let gateway = makeMockGateway(runner)

        let entries = try await gateway.list(url: URL(string: "https://svn.example.com/repos/company/trunk")!)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].name, "SDK")
        XCTAssertEqual(entries[0].kind, SVNListEntry.Kind.directory)
        XCTAssertEqual(entries[0].revision, 12580)
        XCTAssertEqual(entries[1].name, "接口说明.pdf")
        XCTAssertEqual(entries[1].size, 2_621_440)
        XCTAssertEqual(runner.calls.single, ["svn", "list", "https://svn.example.com/repos/company/trunk", "--xml", "--depth", "immediates", "--non-interactive"])
    }

    func testRecursiveListUsesStructuredOutputWithoutVerboseFlag() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <lists><list path="https://svn.example.com/repo">
          <entry kind="dir"><name>技术部</name><commit revision="2" /></entry>
          <entry kind="file"><name>技术部/API.txt</name><size>10</size><commit revision="3" /></entry>
        </list></lists>
        """
        let runner = MockSVNCommandRunner(output: .success(stdout: xml))
        let gateway = makeMockGateway(runner)

        let entries = try await gateway.listRecursively(
            url: URL(string: "https://svn.example.com/repo")!,
            options: .anonymous
        )

        XCTAssertEqual(entries.map(\.name), ["技术部", "技术部/API.txt"])
        XCTAssertEqual(
            runner.calls.single,
            ["svn", "list", "https://svn.example.com/repo", "--xml", "--recursive", "--non-interactive"]
        )
        XCTAssertFalse(try XCTUnwrap(runner.calls.single).contains("--verbose"))
    }

    func testLogMapsHistoryAndUsesPegRevision() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <log>
          <logentry revision="42">
            <author>zhangsan</author>
            <date>2026-09-02T10:20:30.000000Z</date>
            <msg>更新接口说明</msg>
          </logentry>
          <logentry revision="18">
            <msg>首次上传</msg>
          </logentry>
        </log>
        """
        let runner = MockSVNCommandRunner(output: .success(stdout: xml))
        let gateway = makeMockGateway(runner)
        let url = try XCTUnwrap(URL(string: "https://svn.example.com/repo/接口说明.pdf"))

        let entries = try await gateway.log(
            url: url,
            pegRevision: 50,
            limit: 100,
            options: .anonymous
        )

        XCTAssertEqual(entries.map(\.revision), [42, 18])
        XCTAssertEqual(entries.first?.author, "zhangsan")
        XCTAssertEqual(entries.first?.message, "更新接口说明")
        XCTAssertNotNil(entries.first?.date)
        XCTAssertEqual(entries.last?.author, nil)
        XCTAssertEqual(
            runner.calls.single,
            [
                "svn", "log",
                "https://svn.example.com/repo/%E6%8E%A5%E5%8F%A3%E8%AF%B4%E6%98%8E.pdf@50",
                "--xml", "--limit", "100", "--non-interactive"
            ]
        )
    }

    func testCredentialsUseStandardInputAndCertificateTrustIsScopedToRequest() async throws {
        let fixtureURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "svn-list", withExtension: "xml"))
        let runner = MockSVNCommandRunner(output: .success(stdout: try Data(contentsOf: fixtureURL)))
        let gateway = makeMockGateway(runner)
        let password = "not-visible-in-process-list"

        _ = try await gateway.list(
            url: URL(string: "https://svn.example.com/repos/company")!,
            options: SVNRequestOptions(
                credentials: SVNCredentials(username: "zhangsan", password: password),
                certificateTrustPolicy: .allowUnknownCertificateAuthority
            )
        )

        let call = try XCTUnwrap(runner.invocations.single)
        XCTAssertTrue(call.arguments.contains("--password-from-stdin"))
        XCTAssertTrue(call.arguments.contains("--no-auth-cache"))
        XCTAssertTrue(call.arguments.contains("--trust-server-cert-failures=unknown-ca"))
        XCTAssertFalse(call.arguments.contains(password))
        XCTAssertEqual(call.standardInput, Data((password + "\n").utf8))
    }

    func testCertificateBypassIsNotAppliedToNonHTTPSRepositories() async throws {
        let fixtureURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "svn-list", withExtension: "xml"))
        let runner = MockSVNCommandRunner(output: .success(stdout: try Data(contentsOf: fixtureURL)))
        let gateway = makeMockGateway(runner)

        _ = try await gateway.list(
            url: URL(string: "svn://svn.example.com/repos/company")!,
            options: SVNRequestOptions(credentials: nil, certificateTrustPolicy: .allowAllFailures)
        )

        XCTAssertFalse(try XCTUnwrap(runner.invocations.single).arguments.contains { $0.hasPrefix("--trust-server-cert") })
    }

    func testAtSignInRepositoryPathIsEscapedFromSVNPegRevisionParsing() async throws {
        let fixtureURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "svn-list", withExtension: "xml"))
        let runner = MockSVNCommandRunner(output: .success(stdout: try Data(contentsOf: fixtureURL)))
        let gateway = makeMockGateway(runner)

        _ = try await gateway.list(url: URL(string: "https://svn.example.com/repos/a@b")!)

        XCTAssertTrue(try XCTUnwrap(runner.invocations.single).arguments.contains("https://svn.example.com/repos/a@b@"))
    }

    func testAllowAllCertificateFailuresUsesExplicitSupportedFailureList() async throws {
        let fixtureURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "svn-list", withExtension: "xml"))
        let runner = MockSVNCommandRunner(output: .success(stdout: try Data(contentsOf: fixtureURL)))
        let gateway = makeMockGateway(runner)

        _ = try await gateway.list(
            url: URL(string: "https://svn.example.com/repos/company")!,
            options: SVNRequestOptions(credentials: nil, certificateTrustPolicy: .allowAllFailures)
        )

        XCTAssertTrue(try XCTUnwrap(runner.invocations.single).arguments.contains(
            "--trust-server-cert-failures=unknown-ca,cn-mismatch,expired,not-yet-valid,other"
        ))
    }

    func testBatchDeleteUsesOneSVNCommitWithAllTargets() async throws {
        let runner = MockSVNCommandRunner(output: .success(stdout: "Committed revision 24.\n"))
        let gateway = makeMockGateway(runner)
        let first = try XCTUnwrap(URL(string: "https://svn.example.com/repo/说明.txt"))
        let second = try XCTUnwrap(URL(string: "https://svn.example.com/repo/资料"))

        let result = try await gateway.delete(
            urls: [first, second],
            message: "删除 2 项",
            options: .anonymous
        )

        XCTAssertEqual(result.revision, 24)
        XCTAssertEqual(
            runner.calls.single,
            [
                "svn", "delete",
                "https://svn.example.com/repo/%E8%AF%B4%E6%98%8E.txt",
                "https://svn.example.com/repo/%E8%B5%84%E6%96%99",
                "--message", "删除 2 项", "--non-interactive"
            ]
        )
    }

    func testNonZeroExitBecomesStructuredError() async {
        let runner = MockSVNCommandRunner(output: .init(stdout: "", stderr: "E170013: Unable to connect", status: 1))
        let gateway = makeMockGateway(runner)

        do {
            _ = try await gateway.version()
            XCTFail("Expected command failure")
        } catch let SVNClientError.commandFailed(failure) {
            XCTAssertEqual(failure.operation, "version")
            XCTAssertEqual(failure.exitStatus, 1)
            XCTAssertEqual(failure.standardError, "E170013: Unable to connect")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCommandFailureProvidesUserFacingMessageWithoutRawDiagnostic() {
        let error = SVNClientError.commandFailed(SVNCommandFailure(
            operation: "list",
            exitStatus: 1,
            standardOutput: "",
            standardError: "svn: E170013: Unable to connect to a repository at URL 'https://secret.example.com'"
        ))

        XCTAssertEqual(error.localizedDescription, "无法连接 SVN 仓库，请检查地址和网络")
        XCTAssertFalse(error.localizedDescription.contains("secret.example.com"))
    }

    func testCertificateFailureProvidesActionableMessageBeforeGenericConnectionError() {
        let error = SVNClientError.commandFailed(SVNCommandFailure(
            operation: "list",
            exitStatus: 1,
            standardOutput: "",
            standardError: "svn: E170013: Unable to connect\nsvn: E230001: Server SSL certificate verification failed"
        ))

        XCTAssertEqual(
            error.localizedDescription,
            "HTTPS 证书验证失败；请确认服务器身份，或在服务器配置中选择适合的证书策略"
        )
    }

    func testListStopsWaitingAfterConnectionTimeout() async {
        let gateway = SVNCLIGateway(
            runner: HangingSVNCommandRunner(),
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            executableName: "svn",
            connectionTimeout: .milliseconds(20)
        )

        do {
            _ = try await gateway.list(url: URL(string: "https://svn.example.com/repo")!)
            XCTFail("Expected connection timeout")
        } catch let error as SVNClientError {
            XCTAssertEqual(error, .connectionTimedOut)
            XCTAssertEqual(
                error.localizedDescription,
                "连接或读取 SVN 服务器超过 10 秒，已停止等待；请检查服务器地址和网络"
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

}

private struct ExportDestinationRaceRunner: SVNCommandRunning {
    let destination: URL
    let isDirectory: Bool
    func run(executableURL: URL, arguments: [String], environment: [String: String]?, standardInput: Data?) async throws -> SVNProcessOutput {
        let partial = URL(fileURLWithPath: arguments[2])
        if isDirectory {
            try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        }
        let partialContent = isDirectory ? partial.appendingPathComponent("content.txt") : partial
        let destinationContent = isDirectory ? destination.appendingPathComponent("content.txt") : destination
        try Data("repository-content".utf8).write(to: partialContent)
        try Data("user-created-content".utf8).write(to: destinationContent)
        return SVNProcessOutput(standardOutput: Data(), standardError: Data(), exitStatus: 0)
    }
}

private actor HangingSVNCommandRunner: SVNCommandRunning {
    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?,
        standardInput: Data?
    ) async throws -> SVNProcessOutput {
        try await Task.sleep(for: .seconds(60))
        return SVNProcessOutput(standardOutput: Data(), standardError: Data(), exitStatus: 0)
    }
}

private final class MockSVNCommandRunner: SVNCommandRunning, @unchecked Sendable {
    struct Invocation {
        let arguments: [String]
        let environment: [String: String]?
        let standardInput: Data?
    }

    struct Output {
        let standardOutput: Data
        let standardError: Data
        let status: Int32

        init(standardOutput: Data, standardError: Data, status: Int32) {
            self.standardOutput = standardOutput
            self.standardError = standardError
            self.status = status
        }

        static func success(stdout: String) -> Output {
            Output(standardOutput: Data(stdout.utf8), standardError: Data(), status: 0)
        }

        static func success(stdout: Data) -> Output {
            Output(standardOutput: stdout, standardError: Data(), status: 0)
        }

        init(stdout: String, stderr: String, status: Int32) {
            self.standardOutput = Data(stdout.utf8)
            self.standardError = Data(stderr.utf8)
            self.status = status
        }
    }

    private let output: Output
    private(set) var invocations: [Invocation] = []

    var calls: [[String]] { invocations.map(\.arguments) }

    init(output: Output) {
        self.output = output
    }

    func run(executableURL: URL, arguments: [String], environment: [String: String]?, standardInput: Data?) async throws -> SVNProcessOutput {
        invocations.append(Invocation(arguments: arguments, environment: environment, standardInput: standardInput))
        return SVNProcessOutput(standardOutput: output.standardOutput, standardError: output.standardError, exitStatus: output.status)
    }
}

private actor CheckoutVerificationFailureRunner: SVNCommandRunning {
    private var invocationCount = 0

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?,
        standardInput: Data?
    ) async throws -> SVNProcessOutput {
        invocationCount += 1
        let currentInvocation = invocationCount
        if currentInvocation == 1 {
            let partialPath = arguments[2]
            try FileManager.default.createDirectory(atPath: partialPath, withIntermediateDirectories: true)
            try Data("content".utf8).write(to: URL(fileURLWithPath: partialPath).appendingPathComponent("file.txt"))
            return SVNProcessOutput(standardOutput: Data(), standardError: Data(), exitStatus: 0)
        }
        return SVNProcessOutput(
            standardOutput: Data("not xml".utf8),
            standardError: Data(),
            exitStatus: 0
        )
    }
}

private extension Array where Element == [String] {
    var single: [String]? {
        count == 1 ? first : nil
    }
}

private extension Array where Element == MockSVNCommandRunner.Invocation {
    var single: Element? {
        count == 1 ? first : nil
    }
}
