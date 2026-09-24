import Foundation

@MainActor
final class WorkingCopyViewModel {
    enum State: Equatable {
        case empty
        case loading
        case ready
        case failed(String)
    }

    var onChange: (() -> Void)?

    private let service: WorkingCopyService
    private var refreshRequestID = UUID()

    private(set) var workingCopy: WorkingCopy?
    private(set) var snapshot: WorkingCopySnapshot?
    private(set) var state: State = .empty

    init(service: WorkingCopyService) {
        self.service = service
    }

    var isRefreshing: Bool { state == .loading }

    func open(_ workingCopy: WorkingCopy) async throws {
        let requestID = UUID()
        refreshRequestID = requestID
        self.workingCopy = workingCopy
        snapshot = nil
        state = .loading
        onChange?()
        let openedWorkingCopy: WorkingCopy
        do {
            openedWorkingCopy = try await service.markOpened(workingCopy)
            try Task.checkCancellation()
        } catch is CancellationError {
            guard refreshRequestID == requestID else { throw CancellationError() }
            state = .failed("读取已取消")
            onChange?()
            throw CancellationError()
        } catch {
            guard refreshRequestID == requestID, self.workingCopy?.id == workingCopy.id else { return }
            state = .failed(error.localizedDescription)
            onChange?()
            throw error
        }
        guard refreshRequestID == requestID, self.workingCopy?.id == workingCopy.id else { return }
        self.workingCopy = openedWorkingCopy
        try await refresh()
    }

    func refresh() async throws {
        guard let workingCopy else { return }
        let requestID = UUID()
        refreshRequestID = requestID
        state = .loading
        onChange?()
        do {
            let loadedSnapshot = try await service.snapshot(for: workingCopy)
            try Task.checkCancellation()
            guard refreshRequestID == requestID, self.workingCopy?.id == workingCopy.id else { return }
            snapshot = loadedSnapshot
            state = .ready
            onChange?()
        } catch is CancellationError {
            guard refreshRequestID == requestID else { return }
            state = snapshot == nil ? .failed("刷新已取消，可点击刷新重试") : .ready
            onChange?()
            throw CancellationError()
        } catch {
            guard refreshRequestID == requestID, self.workingCopy?.id == workingCopy.id else { return }
            state = .failed(error.localizedDescription)
            onChange?()
            throw error
        }
    }

    func close() {
        refreshRequestID = UUID()
        workingCopy = nil
        snapshot = nil
        state = .empty
        onChange?()
    }
}
