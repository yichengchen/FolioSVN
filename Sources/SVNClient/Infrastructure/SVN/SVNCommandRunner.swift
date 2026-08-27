import Foundation

struct SVNProcessOutput: Sendable {
    let standardOutput: Data
    let standardError: Data
    let exitStatus: Int32
}

protocol SVNCommandRunning: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?,
        standardInput: Data?
    ) async throws -> SVNProcessOutput
}

final class ProcessSVNCommandRunner: SVNCommandRunning, Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?,
        standardInput: Data?
    ) async throws -> SVNProcessOutput {
        let state = ProcessExecutionState()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                let standardOutput = Pipe()
                let standardError = Pipe()
                let standardInputPipe = standardInput.map { _ in Pipe() }
                let collector = ProcessOutputCollector { result in
                    state.resume(continuation, with: result)
                }

                process.executableURL = executableURL
                process.arguments = arguments
                process.environment = environment
                process.standardOutput = standardOutput
                process.standardError = standardError
                process.standardInput = standardInputPipe
                state.set(process)
                collector.beginReading(stdout: standardOutput, stderr: standardError)
                process.terminationHandler = { terminatedProcess in
                    collector.recordTermination(
                        exitStatus: terminatedProcess.terminationStatus,
                        wasCancelled: state.isCancelled
                    )
                }

                do {
                    try process.run()
                    if let standardInput, let standardInputPipe {
                        standardInputPipe.fileHandleForWriting.write(standardInput)
                        try? standardInputPipe.fileHandleForWriting.close()
                    }
                    if state.isCancelled { process.terminate() }
                } catch {
                    try? standardOutput.fileHandleForWriting.close()
                    try? standardError.fileHandleForWriting.close()
                    collector.fail(error)
                }
            }
        }, onCancel: {
            state.terminate()
        })
    }
}

private final class ProcessExecutionState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var didResume = false
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func set(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    func terminate() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    func resume(
        _ continuation: CheckedContinuation<SVNProcessOutput, Error>,
        with result: Result<SVNProcessOutput, Error>
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        continuation.resume(with: result)
    }
}

private final class ProcessOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let completion: @Sendable (Result<SVNProcessOutput, Error>) -> Void
    private var standardOutput: Data?
    private var standardError: Data?
    private var exitStatus: Int32?
    private var wasCancelled = false
    private var didComplete = false

    init(completion: @escaping @Sendable (Result<SVNProcessOutput, Error>) -> Void) {
        self.completion = completion
    }

    func beginReading(stdout: Pipe, stderr: Pipe) {
        DispatchQueue.global(qos: .utility).async { [self] in
            recordStandardOutput(stdout.fileHandleForReading.readDataToEndOfFile())
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            recordStandardError(stderr.fileHandleForReading.readDataToEndOfFile())
        }
    }

    func recordTermination(exitStatus: Int32, wasCancelled: Bool) {
        lock.lock()
        self.exitStatus = exitStatus
        self.wasCancelled = wasCancelled
        completeIfReadyLocked()
        lock.unlock()
    }

    func fail(_ error: Error) {
        lock.lock()
        guard !didComplete else { lock.unlock(); return }
        didComplete = true
        lock.unlock()
        completion(.failure(error))
    }

    private func recordStandardOutput(_ data: Data) {
        lock.lock()
        standardOutput = data
        completeIfReadyLocked()
        lock.unlock()
    }

    private func recordStandardError(_ data: Data) {
        lock.lock()
        standardError = data
        completeIfReadyLocked()
        lock.unlock()
    }

    private func completeIfReadyLocked() {
        guard !didComplete, let standardOutput, let standardError, let exitStatus else { return }
        didComplete = true
        let result: Result<SVNProcessOutput, Error> = wasCancelled
            ? .failure(CancellationError())
            : .success(SVNProcessOutput(standardOutput: standardOutput, standardError: standardError, exitStatus: exitStatus))
        completion(result)
    }
}
