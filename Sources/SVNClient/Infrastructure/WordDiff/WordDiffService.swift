import Foundation

struct WordDiffResult: Sendable {
    let directoryURL: URL
    let documentURL: URL
    let htmlURL: URL
    let revisionCount: Int
}

enum WordDiffError: LocalizedError, Sendable {
    case unavailable
    case failed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .unavailable: return "内置 Word 比较器缺失，请运行 Scripts/package-worddiff-runtime.sh 后重新构建。"
        case .failed(let message): return "Word 比较失败：\(message)"
        case .timedOut: return "Word 比较超时，请尝试较小的文档。"
        }
    }
}

struct WordDiffService: Sendable {
    private let runner: any SVNCommandRunning
    private let executableURL: URL?

    init(runner: any SVNCommandRunning = ProcessSVNCommandRunner(), executableURL: URL? = nil) {
        self.runner = runner
        self.executableURL = executableURL ?? Bundle.main.resourceURL?
            .appendingPathComponent("WordDiffRuntime/worddiff-demo")
    }

    func compare(original: URL, revised: URL) async throws -> WordDiffResult {
        guard let executableURL, FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw WordDiffError.unavailable
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("folio-worddiff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let document = directory.appendingPathComponent("compared.docx")
            let html = directory.appendingPathComponent("compared.html")
            let output = try await withThrowingTaskGroup(of: SVNProcessOutput.self) { group in
                group.addTask {
                    try await runner.run(executableURL: executableURL,
                        arguments: ["compare", original.path, revised.path, document.path],
                        environment: nil, standardInput: nil)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(120))
                    throw WordDiffError.timedOut
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            let response = try JSONDecoder().decode(Response.self, from: output.standardOutput)
            guard output.exitStatus == 0, response.status == "success",
                  FileManager.default.fileExists(atPath: document.path),
                  FileManager.default.fileExists(atPath: html.path) else {
                throw WordDiffError.failed(response.message ?? "比较器未生成结果")
            }
            return WordDiffResult(directoryURL: directory, documentURL: document, htmlURL: html,
                revisionCount: response.revisionCount ?? 0)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            if error is CancellationError { throw error }
            if error is WordDiffError { throw error }
            throw WordDiffError.failed(error.localizedDescription)
        }
    }

    private struct Response: Decodable {
        let status: String
        let message: String?
        let revisionCount: Int?
    }
}
