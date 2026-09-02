import Foundation
import XMLCoder

protocol SVNClient: Sendable {
    func version() async throws -> String
    func list(url: URL, options: SVNRequestOptions) async throws -> [SVNListEntry]
    func listRecursively(url: URL, options: SVNRequestOptions) async throws -> [SVNListEntry]
    func info(url: URL, options: SVNRequestOptions) async throws -> SVNItemInfo
    func export(url: URL, to destinationURL: URL, revision: Int?, overwrite: Bool, options: SVNRequestOptions) async throws
    func makeDirectory(url: URL, message: String, options: SVNRequestOptions) async throws -> SVNWriteResult
    func move(from sourceURL: URL, to destinationURL: URL, message: String, options: SVNRequestOptions) async throws -> SVNWriteResult
    func delete(url: URL, message: String, options: SVNRequestOptions) async throws -> SVNWriteResult
    func upload(files: [URL], to directoryURL: URL, message: String, options: SVNRequestOptions) async throws -> SVNWriteResult
    func replace(localFileURL: URL, targetURL: URL, expectedRevision: Int, message: String, options: SVNRequestOptions) async throws -> SVNWriteResult
}

extension SVNClient {
    func list(url: URL) async throws -> [SVNListEntry] {
        try await list(url: url, options: .anonymous)
    }

    func info(url: URL, options: SVNRequestOptions) async throws -> SVNItemInfo {
        throw SVNClientError.unsupportedOperation
    }

    func listRecursively(url: URL, options: SVNRequestOptions) async throws -> [SVNListEntry] {
        throw SVNClientError.unsupportedOperation
    }

    func export(url: URL, to destinationURL: URL, revision: Int?, overwrite: Bool, options: SVNRequestOptions) async throws {
        throw SVNClientError.unsupportedOperation
    }

    func makeDirectory(url: URL, message: String, options: SVNRequestOptions) async throws -> SVNWriteResult {
        throw SVNClientError.unsupportedOperation
    }

    func move(from sourceURL: URL, to destinationURL: URL, message: String, options: SVNRequestOptions) async throws -> SVNWriteResult {
        throw SVNClientError.unsupportedOperation
    }

    func delete(url: URL, message: String, options: SVNRequestOptions) async throws -> SVNWriteResult {
        throw SVNClientError.unsupportedOperation
    }

    func upload(files: [URL], to directoryURL: URL, message: String, options: SVNRequestOptions) async throws -> SVNWriteResult {
        throw SVNClientError.unsupportedOperation
    }

    func replace(localFileURL: URL, targetURL: URL, expectedRevision: Int, message: String, options: SVNRequestOptions) async throws -> SVNWriteResult {
        throw SVNClientError.unsupportedOperation
    }
}

struct SVNCredentials: Equatable, Sendable {
    let username: String
    let password: String
}

enum SVNCertificateTrustPolicy: String, Equatable, Sendable {
    case strict
    case allowUnknownCertificateAuthority
    case allowAllFailures

    var failureArgument: String? {
        switch self {
        case .strict:
            return nil
        case .allowUnknownCertificateAuthority:
            return "unknown-ca"
        case .allowAllFailures:
            return "unknown-ca,cn-mismatch,expired,not-yet-valid,other"
        }
    }
}

struct SVNRequestOptions: Equatable, Sendable {
    static let anonymous = SVNRequestOptions(credentials: nil, certificateTrustPolicy: .strict)

    let credentials: SVNCredentials?
    let certificateTrustPolicy: SVNCertificateTrustPolicy
}

struct SVNListEntry: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case file
        case directory

        init?(svnValue: String) {
            switch svnValue {
            case "file": self = .file
            case "dir": self = .directory
            default: return nil
            }
        }
    }

    let name: String
    let kind: Kind
    let size: Int64?
    let revision: Int?
    let author: String?
    let updatedAt: Date?
}

struct SVNItemInfo: Equatable, Sendable {
    let name: String
    let url: URL
    let kind: SVNListEntry.Kind
    let size: Int64?
    let revision: Int
    let lastChangedRevision: Int?
    let author: String?
    let updatedAt: Date?
    let properties: [String: String]
}

struct SVNWriteResult: Equatable, Sendable {
    let revision: Int?
}

struct SVNCommandFailure: Error, Equatable, Sendable {
    let operation: String
    let exitStatus: Int32
    let standardOutput: String
    let standardError: String
}

enum SVNClientError: Error, Equatable, Sendable {
    case commandFailed(SVNCommandFailure)
    case invalidVersionOutput
    case invalidListXML
    case invalidInfoXML
    case invalidPropertiesXML
    case destinationExists
    case invalidLocalFile(String)
    case duplicateLocalFileName(String)
    case remoteChanged
    case connectionTimedOut
    case unsupportedOperation
}

extension SVNClientError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .commandFailed(failure):
            let diagnostic = failure.standardError
            if diagnostic.contains("E230001")
                || diagnostic.localizedCaseInsensitiveContains("certificate verification failed")
                || diagnostic.localizedCaseInsensitiveContains("server ssl certificate") {
                return "HTTPS 证书验证失败；请确认服务器身份，或在服务器配置中选择适合的证书策略"
            }
            if diagnostic.contains("E170001") || diagnostic.contains("E215004") {
                return "仓库认证失败，请检查凭据"
            }
            if diagnostic.contains("E175013") {
                return "没有读取该仓库位置的权限"
            }
            if diagnostic.contains("E170013") {
                return "无法连接 SVN 仓库，请检查地址和网络"
            }
            if diagnostic.contains("E160013") || diagnostic.contains("E200009") {
                return "仓库位置不存在"
            }
            if diagnostic.contains("E155011") || diagnostic.contains("E160028") || diagnostic.contains("out of date") {
                return "文件已被其他人更新，请刷新后重试"
            }
            if diagnostic.contains("E160020") || diagnostic.contains("already exists") {
                return "当前文件夹已存在同名项目"
            }
            return "SVN 操作失败（退出码 \(failure.exitStatus)）"
        case .invalidVersionOutput:
            return "无法识别 SVN 客户端版本"
        case .invalidListXML:
            return "仓库返回了无法解析的目录数据"
        case .invalidInfoXML:
            return "仓库返回了无法解析的文件信息"
        case .invalidPropertiesXML:
            return "仓库返回了无法解析的属性信息"
        case .destinationExists:
            return "本地目标已存在"
        case let .invalidLocalFile(name):
            return "无法读取本地文件：\(name)"
        case let .duplicateLocalFileName(name):
            return "选择中包含同名文件：\(name)"
        case .remoteChanged:
            return "文件已被其他人更新，请刷新后重试"
        case .connectionTimedOut:
            return "连接或读取 SVN 服务器超过 10 秒，已停止等待；请检查服务器地址和网络"
        case .unsupportedOperation:
            return "当前 SVN 客户端不支持此操作"
        }
    }
}

final class SVNCLIGateway: SVNClient, Sendable {
    private let runner: any SVNCommandRunning
    private let executableURL: URL
    private let executablePrefix: [String]
    private let commandEnvironment: [String: String]
    private let connectionTimeout: Duration

    init(
        runner: any SVNCommandRunning = ProcessSVNCommandRunner(),
        executableURL: URL? = nil,
        executableName: String? = nil,
        connectionTimeout: Duration = .seconds(10)
    ) {
        self.runner = runner
        self.connectionTimeout = connectionTimeout
        let resolvedExecutableURL: URL
        let resolvedExecutablePrefix: [String]
        if let executableURL {
            resolvedExecutableURL = executableURL
            resolvedExecutablePrefix = executableName.map { [$0] } ?? []
        } else if let resolvedURL = SVNExecutableResolver.resolve() {
            resolvedExecutableURL = resolvedURL
            resolvedExecutablePrefix = []
        } else {
            resolvedExecutableURL = URL(fileURLWithPath: "/usr/bin/env")
            resolvedExecutablePrefix = ["svn"]
        }
        self.executableURL = resolvedExecutableURL
        self.executablePrefix = resolvedExecutablePrefix

        var environment = ProcessInfo.processInfo.environment.merging(
            ["LC_ALL": "en_US.UTF-8", "LANG": "en_US.UTF-8"],
            uniquingKeysWith: { _, new in new }
        )
        let bundledCABundle = resolvedExecutableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("etc/ssl/cert.pem")
        if FileManager.default.fileExists(atPath: bundledCABundle.path) {
            environment["SSL_CERT_FILE"] = bundledCABundle.path
            environment.removeValue(forKey: "SSL_CERT_DIR")
        }
        self.commandEnvironment = environment
    }

    func version() async throws -> String {
        let output = try await execute(
            operation: "version",
            arguments: ["--version", "--quiet"],
            timeout: connectionTimeout
        )
        guard let rawVersion = String(data: output.standardOutput, encoding: .utf8) else {
            throw SVNClientError.invalidVersionOutput
        }
        let version = rawVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else {
            throw SVNClientError.invalidVersionOutput
        }
        return version
    }

    func list(url: URL, options: SVNRequestOptions) async throws -> [SVNListEntry] {
        var arguments = ["list", Self.svnTarget(url.absoluteString), "--xml", "--depth", "immediates", "--non-interactive"]
        var standardInput: Data?

        if let credentials = options.credentials {
            arguments += ["--username", credentials.username, "--password-from-stdin", "--no-auth-cache"]
            standardInput = Data((credentials.password + "\n").utf8)
        }
        if url.scheme?.lowercased() == "https",
           let failures = options.certificateTrustPolicy.failureArgument {
            arguments.append("--trust-server-cert-failures=\(failures)")
        }

        let output = try await execute(
            operation: "list",
            arguments: arguments,
            standardInput: standardInput,
            timeout: connectionTimeout
        )
        do {
            let decoder = XMLDecoder()
            return try decoder.decode(SVNListDocumentDTO.self, from: output.standardOutput).list.entry.map(SVNListEntry.init)
        } catch {
            throw SVNClientError.invalidListXML
        }
    }

    func listRecursively(url: URL, options: SVNRequestOptions) async throws -> [SVNListEntry] {
        var arguments = ["list", Self.svnTarget(url.absoluteString), "--xml", "--recursive", "--non-interactive"]
        var standardInput: Data?

        if let credentials = options.credentials {
            arguments += ["--username", credentials.username, "--password-from-stdin", "--no-auth-cache"]
            standardInput = Data((credentials.password + "\n").utf8)
        }
        if url.scheme?.lowercased() == "https",
           let failures = options.certificateTrustPolicy.failureArgument {
            arguments.append("--trust-server-cert-failures=\(failures)")
        }

        let output = try await execute(
            operation: "list-recursive",
            arguments: arguments,
            standardInput: standardInput
        )
        do {
            return try XMLDecoder()
                .decode(SVNListDocumentDTO.self, from: output.standardOutput)
                .list.entry.map(SVNListEntry.init)
        } catch {
            throw SVNClientError.invalidListXML
        }
    }

    func info(url: URL, options: SVNRequestOptions) async throws -> SVNItemInfo {
        let infoOutput = try await executeAuthenticated(
            operation: "info",
            arguments: ["info", Self.svnTarget(url.absoluteString), "--xml"],
            urls: [url],
            options: options,
            timeout: connectionTimeout
        )
        let propertiesOutput = try await executeAuthenticated(
            operation: "proplist",
            arguments: ["proplist", Self.svnTarget(url.absoluteString), "--xml", "--verbose"],
            urls: [url],
            options: options,
            timeout: connectionTimeout
        )

        let infoDTO: SVNInfoDocumentDTO
        let propertiesDTO: SVNPropertiesDocumentDTO
        do {
            infoDTO = try XMLDecoder().decode(SVNInfoDocumentDTO.self, from: infoOutput.standardOutput)
        } catch {
            throw SVNClientError.invalidInfoXML
        }
        do {
            propertiesDTO = try XMLDecoder().decode(SVNPropertiesDocumentDTO.self, from: propertiesOutput.standardOutput)
        } catch {
            throw SVNClientError.invalidPropertiesXML
        }

        guard let kind = SVNListEntry.Kind(svnValue: infoDTO.entry.kind),
              let decodedURL = URL(string: infoDTO.entry.url) else {
            throw SVNClientError.invalidInfoXML
        }
        let properties = Dictionary(
            uniqueKeysWithValues: (propertiesDTO.target?.first?.property ?? []).map { ($0.name, $0.value) }
        )
        return SVNItemInfo(
            name: infoDTO.entry.path,
            url: decodedURL,
            kind: kind,
            size: infoDTO.entry.size,
            revision: infoDTO.entry.revision,
            lastChangedRevision: infoDTO.entry.commit?.revision,
            author: infoDTO.entry.commit?.author,
            updatedAt: infoDTO.entry.commit?.date.flatMap(Self.parseSVNDate),
            properties: properties
        )
    }

    func export(
        url: URL,
        to destinationURL: URL,
        revision: Int?,
        overwrite: Bool,
        options: SVNRequestOptions
    ) async throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path), !overwrite {
            throw SVNClientError.destinationExists
        }
        let partialURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".svnclient-partial-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: partialURL) }

        var arguments = ["export", Self.svnTarget(url.absoluteString), partialURL.path, "--ignore-externals"]
        if let revision {
            arguments += ["--revision", String(revision)]
        }
        _ = try await executeAuthenticated(
            operation: "export",
            arguments: arguments,
            urls: [url],
            options: options
        )

        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: partialURL)
        } else {
            try fileManager.moveItem(at: partialURL, to: destinationURL)
        }
    }

    func makeDirectory(url: URL, message: String, options: SVNRequestOptions) async throws -> SVNWriteResult {
        let output = try await executeAuthenticated(
            operation: "mkdir",
            arguments: ["mkdir", Self.svnTarget(url.absoluteString), "--message", message],
            urls: [url],
            options: options
        )
        return SVNWriteResult(revision: Self.parseCommittedRevision(output))
    }

    func move(
        from sourceURL: URL,
        to destinationURL: URL,
        message: String,
        options: SVNRequestOptions
    ) async throws -> SVNWriteResult {
        let output = try await executeAuthenticated(
            operation: "move",
            arguments: ["move", Self.svnTarget(sourceURL.absoluteString), Self.svnTarget(destinationURL.absoluteString), "--message", message],
            urls: [sourceURL, destinationURL],
            options: options
        )
        return SVNWriteResult(revision: Self.parseCommittedRevision(output))
    }

    func delete(url: URL, message: String, options: SVNRequestOptions) async throws -> SVNWriteResult {
        let output = try await executeAuthenticated(
            operation: "delete",
            arguments: ["delete", Self.svnTarget(url.absoluteString), "--message", message],
            urls: [url],
            options: options
        )
        return SVNWriteResult(revision: Self.parseCommittedRevision(output))
    }

    func upload(
        files: [URL],
        to directoryURL: URL,
        message: String,
        options: SVNRequestOptions
    ) async throws -> SVNWriteResult {
        let names = files.map(\.lastPathComponent)
        if let duplicate = Dictionary(grouping: names, by: { $0 }).first(where: { $0.value.count > 1 })?.key {
            throw SVNClientError.duplicateLocalFileName(duplicate)
        }
        for fileURL in files {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw SVNClientError.invalidLocalFile(fileURL.lastPathComponent)
            }
        }

        return try await withTemporaryWorkingCopy(for: directoryURL, options: options) { workspaceURL in
            let localTargets = try files.map { sourceURL in
                let targetURL = workspaceURL.appendingPathComponent(sourceURL.lastPathComponent)
                try FileManager.default.copyItem(at: sourceURL, to: targetURL)
                return targetURL
            }
            _ = try await self.executeAuthenticated(
                operation: "add",
                arguments: ["add"] + localTargets.map { Self.svnTarget($0.path) },
                urls: [directoryURL],
                options: options
            )
            let output = try await self.executeAuthenticated(
                operation: "commit",
                arguments: ["commit"] + localTargets.map { Self.svnTarget($0.path) } + ["--message", message],
                urls: [directoryURL],
                options: options
            )
            return SVNWriteResult(revision: Self.parseCommittedRevision(output))
        }
    }

    func replace(
        localFileURL: URL,
        targetURL: URL,
        expectedRevision: Int,
        message: String,
        options: SVNRequestOptions
    ) async throws -> SVNWriteResult {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: localFileURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw SVNClientError.invalidLocalFile(localFileURL.lastPathComponent)
        }
        let currentInfo = try await info(url: targetURL, options: options)
        guard currentInfo.lastChangedRevision == expectedRevision else {
            throw SVNClientError.remoteChanged
        }
        let parentURL = targetURL.deletingLastPathComponent()

        return try await withTemporaryWorkingCopy(for: parentURL, options: options) { workspaceURL in
            let targetLocalURL = workspaceURL.appendingPathComponent(targetURL.lastPathComponent)
            _ = try await self.executeAuthenticated(
                operation: "update",
                arguments: ["update", Self.svnTarget(targetLocalURL.path)],
                urls: [targetURL],
                options: options
            )
            let revisionOutput = try await self.executeAuthenticated(
                operation: "info",
                arguments: ["info", Self.svnTarget(targetLocalURL.path), "--show-item", "last-changed-revision"],
                urls: [targetURL],
                options: options
            )
            let checkedOutRevision = Int(String(decoding: revisionOutput.standardOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
            guard checkedOutRevision == expectedRevision else {
                throw SVNClientError.remoteChanged
            }
            try FileManager.default.removeItem(at: targetLocalURL)
            try FileManager.default.copyItem(at: localFileURL, to: targetLocalURL)
            let output = try await self.executeAuthenticated(
                operation: "commit",
                arguments: ["commit", Self.svnTarget(targetLocalURL.path), "--message", message],
                urls: [targetURL],
                options: options
            )
            return SVNWriteResult(revision: Self.parseCommittedRevision(output))
        }
    }

    private func withTemporaryWorkingCopy<Result: Sendable>(
        for directoryURL: URL,
        options: SVNRequestOptions,
        operation: (URL) async throws -> Result
    ) async throws -> Result {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SVNClient-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }
        _ = try await executeAuthenticated(
            operation: "checkout",
            arguments: ["checkout", Self.svnTarget(directoryURL.absoluteString), workspaceURL.path, "--depth", "empty", "--ignore-externals"],
            urls: [directoryURL],
            options: options,
            timeout: connectionTimeout
        )
        return try await operation(workspaceURL)
    }

    private func executeAuthenticated(
        operation: String,
        arguments: [String],
        urls: [URL],
        options: SVNRequestOptions,
        timeout: Duration? = nil
    ) async throws -> SVNProcessOutput {
        var authenticatedArguments = arguments + ["--non-interactive"]
        var standardInput: Data?
        if let credentials = options.credentials {
            authenticatedArguments += ["--username", credentials.username, "--password-from-stdin", "--no-auth-cache"]
            standardInput = Data((credentials.password + "\n").utf8)
        }
        if urls.contains(where: { $0.scheme?.lowercased() == "https" }),
           let failures = options.certificateTrustPolicy.failureArgument {
            authenticatedArguments.append("--trust-server-cert-failures=\(failures)")
        }
        return try await execute(
            operation: operation,
            arguments: authenticatedArguments,
            standardInput: standardInput,
            timeout: timeout
        )
    }

    private static func parseCommittedRevision(_ output: SVNProcessOutput) -> Int? {
        let text = String(decoding: output.standardOutput, as: UTF8.self)
        guard let range = text.range(of: #"Committed revision\s+(\d+)"#, options: .regularExpression) else {
            return nil
        }
        return Int(text[range].split(separator: " ").last?.trimmingCharacters(in: CharacterSet(charactersIn: ".")) ?? "")
    }

    private static func svnTarget(_ value: String) -> String {
        value.contains("@") ? value + "@" : value
    }

    private static func parseSVNDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    private func execute(
        operation: String,
        arguments: [String],
        standardInput: Data? = nil,
        timeout: Duration? = nil
    ) async throws -> SVNProcessOutput {
        let runCommand: @Sendable () async throws -> SVNProcessOutput = {
            try await self.runner.run(
                executableURL: self.executableURL,
                arguments: self.executablePrefix + arguments,
                environment: self.commandEnvironment,
                standardInput: standardInput
            )
        }
        let output: SVNProcessOutput
        if let timeout {
            output = try await withThrowingTaskGroup(of: SVNProcessOutput.self) { group in
                group.addTask(operation: runCommand)
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw SVNClientError.connectionTimedOut
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else {
                    throw CancellationError()
                }
                return first
            }
        } else {
            output = try await runCommand()
        }
        guard output.exitStatus == 0 else {
            throw SVNClientError.commandFailed(
                SVNCommandFailure(
                    operation: operation,
                    exitStatus: output.exitStatus,
                    standardOutput: String(decoding: output.standardOutput, as: UTF8.self),
                    standardError: String(decoding: output.standardError, as: UTF8.self)
                )
            )
        }
        return output
    }
}
