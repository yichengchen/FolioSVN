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
