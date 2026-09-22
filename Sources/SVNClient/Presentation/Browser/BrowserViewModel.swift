import Foundation
import CryptoKit

struct RepositorySession: Sendable {
    let profileID: UUID
    let displayName: String
    let baseURL: URL
    let options: SVNRequestOptions
}

struct BrowserDownloadRequest: Equatable, Sendable {
    let sourceURL: URL
    let displayName: String
    let byteSize: Int64?
    let revision: Int?
    let options: SVNRequestOptions
}

struct BrowserHistoricalDownloadRequest: Equatable, Sendable {
    let sourceURL: URL
    let displayName: String
    let pegRevision: Int
    let revision: Int
    let options: SVNRequestOptions
}

struct BrowserBatchDownloadItem: Equatable, Sendable {
    let request: BrowserDownloadRequest
    let destinationURL: URL
    let overwrite: Bool
}

struct BrowserBatchDownloadFailure: LocalizedError, Sendable {
    let completedCount: Int
    let failures: [String]

    var errorDescription: String? {
        let names = failures.prefix(3).joined(separator: "、")
        let remaining = failures.count > 3 ? "等" : ""
        return "已完成 \(completedCount) 项，\(failures.count) 项下载失败：\(names)\(remaining)"
    }
}

struct BrowserFileHistory: Sendable {
    let profileID: UUID
    let sourceURL: URL
    let displayName: String
    let currentRevision: Int
    let pegRevision: Int
    let entries: [SVNLogEntry]
    let options: SVNRequestOptions
}

struct BrowserOpenDocumentChange: Identifiable, Equatable, Sendable {
    let id: UUID
    let displayName: String
    let localURL: URL
    let sourceURL: URL
    let modifiedAt: Date?
    let byteSize: Int64?
    let canUpload: Bool
}

struct BrowserTransfer: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case download
        case upload
        case replace

        var isWrite: Bool {
            self == .upload || self == .replace
        }
    }

    enum State: Equatable, Sendable {
        case running
        case completed
        case cancelled
        case failed(String)
    }

    enum Stage: Equatable, Sendable {
        case queued
        case preparing
        case downloading
        case uploadingAndCommitting
        case checkingAndCommitting
        case finalizing

        var text: String {
            switch self {
            case .queued: return "等待开始"
            case .preparing: return "正在准备"
            case .downloading: return "正在下载"
            case .uploadingAndCommitting: return "正在上传并提交"
            case .checkingAndCommitting: return "正在检查远端并提交"
            case .finalizing: return "正在完成"
            }
        }
    }

    enum RetryRequest: Equatable, Sendable {
        case download(BrowserDownloadRequest, destinationURL: URL, overwrite: Bool)
        case historicalDownload(BrowserHistoricalDownloadRequest, destinationURL: URL, overwrite: Bool)
    }

    let id: UUID
    let kind: Kind
    let title: String
    let detail: String
    var state: State
    var stage: Stage
    let outputURL: URL?
    let retryRequest: RetryRequest?
    let isCancellable: Bool
    let startedAt: Date
    var finishedAt: Date?

    var stateText: String {
        switch state {
        case .running: return stage.text
        case .completed: return "已完成"
        case .cancelled: return "已取消"
        case .failed: return "失败"
        }
    }

    var statusDetail: String {
        if case let .failed(message) = state {
            return "\(detail) · \(message)"
        }
        return detail
    }

    var canRetry: Bool {
        guard retryRequest != nil else { return false }
        if case .failed = state { return true }
        return false
    }

    var canCancel: Bool {
        guard isCancellable else { return false }
        if case .running = state { return true }
        return false
    }
}

@MainActor
final class BrowserViewModel {
    private enum ExpandedDirectoryRefreshResult: Sendable {
        case refreshed(URL, [SVNListEntry])
        case failed(String)
    }

    private struct SearchIndexRefreshKey: Hashable {
        let profileID: UUID
        let rootURL: URL
        let generation: UUID
    }

    private struct SharedSearchIndexRefresh {
        let id: UUID
        let task: Task<Void, Error>
    }

    private struct OpenDocumentFingerprint: Codable, Equatable {
        let modifiedAt: Date?
        let byteSize: Int64?
    }

    private struct OpenDocumentManifest: Codable {
        let id: UUID
        let profileID: UUID
        let sourceURL: URL
        let displayName: String
        var expectedRevision: Int?
        var baseline: OpenDocumentFingerprint
        let createdAt: Date
    }

    private struct TrackedOpenDocument {
        var manifest: OpenDocumentManifest
        let localURL: URL
        var options: SVNRequestOptions?
    }

    enum State: Equatable {
        case disconnected
        case loading
        case loaded(URL)
        case failed(String)
    }

    struct Breadcrumb: Equatable {
        let title: String
        let url: URL
    }

    var onChange: (() -> Void)?
    var onRepositoryChanged: ((UUID, URL) -> Void)?
    var onMetadataChanged: (() -> Void)?
    var onDirectoryCacheRefreshed: ((UUID, URL, DirectoryCacheSnapshot) -> Void)?
    var onTreeDirectoryRefreshed: ((URL, [BrowserRow]) -> Void)?

    private(set) var rows: [BrowserRow] = []
    private(set) var state: State = .disconnected
    private(set) var isBusy = false
    private(set) var isCancellable = false
    private(set) var activityText: String?
    private(set) var noticeText: String?
    private(set) var isShowingSearchResults = false
    private(set) var searchQuery = ""
    private(set) var searchIndexedAt: Date?
    private(set) var directoryCachedAt: Date?
    private(set) var directoryTreeGeneration = 0
    private(set) var transfers: [BrowserTransfer] = []
    private(set) var session: RepositorySession?
    private(set) var currentURL: URL?
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    private var browsingRows: [BrowserRow] = []
    private var favoriteURLKeys: Set<String> = []
    private var sessionGeneration = UUID()
    private var directoryRequestID = UUID()
    private var searchRequestID = UUID()
    private var activityID = UUID()
    private var activityTransferID: UUID?
    private let svnClient: any SVNClient
    private let metadataService: RepositoryMetadataService?
    private let cacheRootURL: URL?
    private let ownsEphemeralCacheRoot: Bool
    private let openDocumentSessionID = UUID()
    private static let abandonedOpenDocumentRetention: TimeInterval = 7 * 24 * 60 * 60
    private static let openDocumentManifestName = ".svnclient-open-document.json"
    private static let openDocumentBaselineName = ".svnclient-baseline"
    private var openDocuments: [UUID: TrackedOpenDocument] = [:]
    private var backgroundDirectoryTasks: [URL: (id: UUID, task: Task<Void, Never>)] = [:]
    private var searchIndexRefreshTasks: [SearchIndexRefreshKey: SharedSearchIndexRefresh] = [:]
    private var transferCancellations: [UUID: () -> Void] = [:]

    var activeTransferCount: Int {
        transfers.filter { $0.state == .running }.count
    }

    var hasActiveWriteTransfer: Bool {
        transfers.contains { transfer in
            guard transfer.state == .running else { return false }
            return transfer.kind == .upload || transfer.kind == .replace
        }
    }

    var modifiedOpenDocuments: [BrowserOpenDocumentChange] {
        openDocuments.values.compactMap { document in
            guard let fingerprint = try? openDocumentFingerprint(at: document.localURL),
                  fingerprint != document.manifest.baseline else { return nil }
            return BrowserOpenDocumentChange(
                id: document.manifest.id,
                displayName: document.manifest.displayName,
                localURL: document.localURL,
                sourceURL: document.manifest.sourceURL,
                modifiedAt: fingerprint.modifiedAt,
                byteSize: fingerprint.byteSize,
                canUpload: document.options != nil
            )
        }.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }

    var modifiedURLKeysForCurrentSession: Set<String> {
        guard let profileID = session?.profileID else { return [] }
        return Set(openDocuments.values.compactMap { document in
            guard document.manifest.profileID == profileID,
                  let fingerprint = try? openDocumentFingerprint(at: document.localURL),
                  fingerprint != document.manifest.baseline else { return nil }
            return document.manifest.sourceURL.absoluteString
        })
    }

    func hasLocalChanges(for row: BrowserRow) -> Bool {
        guard row.kind == .file, let profileID = session?.profileID else { return false }
        return modifiedDocument(for: row.url, profileID: profileID) != nil
    }

    func discardLocalChanges(for row: BrowserRow) throws {
        guard let profileID = session?.profileID,
              var document = modifiedDocument(for: row.url, profileID: profileID) else {
            throw SVNClientError.invalidLocalFile("没有需要放弃的本地修改")
        }
        let baselineURL = openDocumentBaselineURL(for: document)
        let sourceURL: URL
        if FileManager.default.fileExists(atPath: baselineURL.path) {
            sourceURL = baselineURL
        } else if let revision = document.manifest.expectedRevision {
            let snapshotURL = try snapshotCacheURL(
                profileID: document.manifest.profileID,
                revision: revision,
                itemURL: document.manifest.sourceURL
            )
            guard FileManager.default.fileExists(atPath: snapshotURL.path) else {
                throw SVNClientError.invalidLocalFile("找不到可用于重置的原始副本")
            }
            sourceURL = snapshotURL
        } else {
            throw SVNClientError.invalidLocalFile("找不到可用于重置的原始副本")
        }
        try overwriteOpenDocument(at: document.localURL, withContentsOf: sourceURL)
        document.manifest.baseline = try openDocumentFingerprint(at: document.localURL)
        try writeOpenDocumentManifest(document)
        openDocuments[document.manifest.id] = document
        noticeText = "已放弃“\(document.manifest.displayName)”的本地修改"
        onChange?()
    }

    init(svnClient: any SVNClient, metadataService: RepositoryMetadataService? = nil, cacheRootURL: URL? = nil) {
        self.svnClient = svnClient
        self.metadataService = metadataService
        if let cacheRootURL {
            self.cacheRootURL = cacheRootURL
            ownsEphemeralCacheRoot = false
        } else if AppRuntimeEnvironment.isRunningTests() {
            self.cacheRootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("FolioSVNTests-\(UUID().uuidString)", isDirectory: true)
            ownsEphemeralCacheRoot = true
        } else {
            self.cacheRootURL = nil
            ownsEphemeralCacheRoot = false
        }
        try? loadTrackedOpenDocuments()
        try? cleanupAbandonedOpenDocumentCopies()
    }

    deinit {
        if ownsEphemeralCacheRoot, let cacheRootURL {
            try? FileManager.default.removeItem(at: cacheRootURL)
        }
    }

    func connect(to url: URL, options: SVNRequestOptions = .anonymous) async throws {
        let name = url.host ?? url.lastPathComponent.removingPercentEncoding ?? "SVN 仓库"
        try await connect(session: RepositorySession(
            profileID: UUID(),
            displayName: name,
            baseURL: url,
            options: options
        ))
    }

    func connect(
        profile: RepositoryProfile,
        password: String?,
        initialURL: URL? = nil,
        prefetchedEntries: [SVNListEntry]? = nil
    ) async throws {
        let connection = RepositoryConnection(profile: profile, password: password)
        try await connect(session: RepositorySession(
            profileID: profile.id,
            displayName: profile.displayName,
            baseURL: profile.baseURL,
            options: connection.requestOptions
        ), initialURL: initialURL ?? profile.startURL, prefetchedEntries: prefetchedEntries)
    }

    func connect(
        session: RepositorySession,
        initialURL: URL? = nil,
        prefetchedEntries: [SVNListEntry]? = nil
    ) async throws {
        cancelBackgroundDirectoryTasks()
        cancelSearchIndexRefreshTasks()
        sessionGeneration = UUID()
        let generation = sessionGeneration
        directoryRequestID = UUID()
        activityID = UUID()
        activityTransferID = nil
        self.session = session
        for id in openDocuments.keys where openDocuments[id]?.manifest.profileID == session.profileID {
            openDocuments[id]?.options = session.options
        }
        currentURL = nil
        rows = []
        browsingRows = []
        favoriteURLKeys = []
        directoryCachedAt = nil
        directoryTreeGeneration += 1
        endSearchMode(restoreRows: false)
        backStack = []
        forwardStack = []
        do {
            let destinationURL = initialURL ?? session.baseURL
            if let prefetchedEntries {
                try Task.checkCancellation()
                let snapshot = DirectoryCacheSnapshot(entries: prefetchedEntries, cachedAt: .now)
                applyDirectoryEntries(snapshot.entries, url: destinationURL, cachedAt: snapshot.cachedAt)
                try? await metadataService?.replaceDirectoryCache(
                    profileID: session.profileID,
                    url: destinationURL,
                    entries: snapshot.entries,
                    cachedAt: snapshot.cachedAt
                )
                onDirectoryCacheRefreshed?(session.profileID, destinationURL, snapshot)
            } else {
                try await load(url: destinationURL, clearRows: true, policy: .preferCache)
            }
            try? await reloadFavorites()
            try Task.checkCancellation()
            guard generation == sessionGeneration else { throw CancellationError() }
            onChange?()
        } catch {
            guard generation == sessionGeneration else { throw CancellationError() }
            self.session = nil
            currentURL = nil
            rows = []
            browsingRows = []
            favoriteURLKeys = []
            directoryCachedAt = nil
            state = error is CancellationError ? .disconnected : .failed(error.localizedDescription)
            isBusy = false
            isCancellable = false
            activityText = nil
            onChange?()
            throw error
        }
    }

    func disconnect(profileID: UUID) {
        guard session?.profileID == profileID else { return }
        cancelBackgroundDirectoryTasks()
        cancelSearchIndexRefreshTasks()
        sessionGeneration = UUID()
        directoryRequestID = UUID()
        activityID = UUID()
        activityTransferID = nil
        session = nil
        currentURL = nil
        rows = []
        browsingRows = []
        backStack = []
        forwardStack = []
        state = .disconnected
        isBusy = false
        isCancellable = false
        activityText = nil
        noticeText = nil
        directoryCachedAt = nil
        favoriteURLKeys = []
        endSearchMode(restoreRows: false)
        onChange?()
    }

    func openDirectory(_ row: BrowserRow) async throws {
        guard row.kind == .directory, let currentURL else { return }
        guard row.url != currentURL else { return }
        try await navigate(to: row.url)
    }

    func navigate(to url: URL) async throws {
        guard let currentURL, url != currentURL else { return }
        endSearchMode(restoreRows: false)
        try await load(url: url, clearRows: true, policy: .preferCache)
        backStack.append(currentURL)
        forwardStack.removeAll()
        onChange?()
    }

    func goBack() async throws {
        guard let destination = backStack.last, let currentURL else { return }
        try await load(url: destination, clearRows: true, policy: .preferCache)
        _ = backStack.popLast()
        forwardStack.append(currentURL)
        onChange?()
    }

    func goForward() async throws {
        guard let destination = forwardStack.last, let currentURL else { return }
        try await load(url: destination, clearRows: true, policy: .preferCache)
        _ = forwardStack.popLast()
        backStack.append(currentURL)
        onChange?()
    }

    func refresh(
        expandedDirectoryURLs: [URL] = [],
        shouldRefreshDirectory: @escaping @MainActor (URL) -> Bool = { _ in true }
    ) async throws {
        guard let session, let currentURL else { return }
        endSearchMode(restoreRows: false)
        try await load(url: currentURL, clearRows: false, policy: .reload)
        let requestID = directoryRequestID
        let generation = sessionGeneration
        let treeGeneration = directoryTreeGeneration
        let svnClient = self.svnClient
        let options = session.options
        onRepositoryChanged?(session.profileID, currentURL)
        var failures: [String] = []
        let directories = Array(Set(expandedDirectoryURLs)).sorted {
            if $0.pathComponents.count != $1.pathComponents.count { return $0.pathComponents.count < $1.pathComponents.count }
            return $0.absoluteString < $1.absoluteString
        }.filter(shouldRefreshDirectory)
        if !directories.isEmpty {
            try await performActivity("正在刷新已展开的文件夹…", cancellable: true) {
                try await withThrowingTaskGroup(of: ExpandedDirectoryRefreshResult.self) { group in
                    var nextIndex = 0
                    let concurrentLimit = min(4, directories.count)
                    for _ in 0..<concurrentLimit {
                        let url = directories[nextIndex]
                        nextIndex += 1
                        group.addTask {
                            do {
                                return .refreshed(url, try await svnClient.list(url: url, options: options))
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                return .failed(url.lastPathComponent)
                            }
                        }
                    }
                    while let result = try await group.next() {
                        switch result {
                        case let .refreshed(url, entries):
                            try self.checkDirectoryRequest(requestID, generation: generation)
                            let cachedAt = Date()
                            if treeGeneration == self.directoryTreeGeneration {
                                try? await self.metadataService?.replaceDirectoryCache(
                                    profileID: session.profileID,
                                    url: url,
                                    entries: entries,
                                    cachedAt: cachedAt
                                )
                                try self.checkDirectoryRequest(requestID, generation: generation)
                                self.onDirectoryCacheRefreshed?(
                                    session.profileID,
                                    url,
                                    DirectoryCacheSnapshot(entries: entries, cachedAt: cachedAt)
                                )
                            }
                            // A folder collapsed while this read was pending needs no UI update.
                            if shouldRefreshDirectory(url) {
                                self.onTreeDirectoryRefreshed?(
                                    url,
                                    entries.map { BrowserRow(entry: $0, parentURL: url) }
                                )
                            }
                        case let .failed(name):
                            failures.append(name)
                        }
                        while nextIndex < directories.count,
                              !shouldRefreshDirectory(directories[nextIndex]) {
                            nextIndex += 1
                        }
                        if nextIndex < directories.count {
                            let url = directories[nextIndex]
                            nextIndex += 1
                            group.addTask {
                                do {
                                    return .refreshed(url, try await svnClient.list(url: url, options: options))
                                } catch is CancellationError {
                                    throw CancellationError()
                                } catch {
                                    return .failed(url.lastPathComponent)
                                }
                            }
                        }
                    }
                }
            }
        }
        try checkDirectoryRequest(requestID, generation: generation)
        noticeText = failures.isEmpty ? "目录缓存已刷新" : "当前目录已刷新 · 子目录刷新失败，保留原内容：" + failures.joined(separator: "、")
        onChange?()
    }

    var canGoBack: Bool { !backStack.isEmpty && !isBusy }
    var canGoForward: Bool { !forwardStack.isEmpty && !isBusy }

    func rows(in directoryURL: URL, forceReload: Bool = false) async throws -> [BrowserRow] {
        guard let session else { throw SVNClientError.unsupportedOperation }
        let sessionID = sessionGeneration
        if !forceReload,
           let snapshot = try? await metadataService?.directoryCache(
               profileID: session.profileID,
               url: directoryURL
           ) {
            try Task.checkCancellation()
            guard sessionID == sessionGeneration else { throw CancellationError() }
            if snapshot.isExpired() { scheduleDirectoryRevalidation(url: directoryURL, session: session, pageRequestID: nil) }
            return snapshot.entries.map { BrowserRow(entry: $0, parentURL: directoryURL) }
        }
        let generation = directoryTreeGeneration
        let entries = try await svnClient.list(url: directoryURL, options: session.options)
        try Task.checkCancellation()
        guard sessionID == sessionGeneration else { throw CancellationError() }
        if generation == directoryTreeGeneration, session.profileID == self.session?.profileID {
            let cachedAt = Date()
            try? await metadataService?.replaceDirectoryCache(
                profileID: session.profileID,
                url: directoryURL,
                entries: entries,
                cachedAt: cachedAt
            )
            try Task.checkCancellation()
            guard sessionID == sessionGeneration, generation == directoryTreeGeneration else { throw CancellationError() }
            if forceReload { onDirectoryCacheRefreshed?(session.profileID, directoryURL, DirectoryCacheSnapshot(entries: entries, cachedAt: cachedAt)) }
        }
        return entries.map { BrowserRow(entry: $0, parentURL: directoryURL) }
    }

    var breadcrumbs: [Breadcrumb] {
        guard let session, let currentURL else { return [] }
        var result = [Breadcrumb(title: session.displayName, url: session.baseURL)]
        let baseComponents = session.baseURL.pathComponents.filter { $0 != "/" }
        let currentComponents = currentURL.pathComponents.filter { $0 != "/" }
        guard currentComponents.count > baseComponents.count else { return result }

        var url = session.baseURL
        for component in currentComponents.dropFirst(baseComponents.count) {
            url.appendPathComponent(component, isDirectory: true)
            result.append(Breadcrumb(title: component.removingPercentEncoding ?? component, url: url))
        }
        return result
    }

    func sort(column: String, ascending: Bool) {
        rows.sort { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind == .directory }
            let comparison: ComparisonResult
            switch column {
            case "size":
                comparison = NSNumber(value: lhs.byteSize ?? -1).compare(NSNumber(value: rhs.byteSize ?? -1))
            case "modified":
                comparison = (lhs.updatedAt ?? .distantPast).compare(rhs.updatedAt ?? .distantPast)
            case "author":
                comparison = lhs.author.localizedStandardCompare(rhs.author)
            case "revision":
                comparison = NSNumber(value: lhs.revision ?? -1).compare(NSNumber(value: rhs.revision ?? -1))
            case "location":
                comparison = lhs.location.localizedStandardCompare(rhs.location)
            default:
                comparison = lhs.name.localizedStandardCompare(rhs.name)
            }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
        onChange?()
    }

    func itemURL(for row: BrowserRow) -> URL {
        row.url
    }

    func download(_ row: BrowserRow, to destinationURL: URL, overwrite: Bool) async throws {
        guard let request = downloadRequest(for: row) else { return }
        try await download(request, to: destinationURL, overwrite: overwrite)
    }

    func downloadRequest(for row: BrowserRow) -> BrowserDownloadRequest? {
        guard let session else { return nil }
        return BrowserDownloadRequest(
            sourceURL: row.url,
            displayName: row.name,
            byteSize: row.byteSize,
            revision: row.kind == .file ? row.revision : nil,
            options: session.options
        )
    }

    func download(_ request: BrowserDownloadRequest, to destinationURL: URL, overwrite: Bool) async throws {
        let sizeText = request.byteSize.map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        } ?? "大小未知"
        try await performTransfer(
            kind: .download,
            title: "下载 \(request.displayName)",
            detail: "\(sizeText) · 保存为 \(destinationURL.lastPathComponent)",
            cancellable: true,
            outputURL: destinationURL,
            retryRequest: .download(request, destinationURL: destinationURL, overwrite: overwrite)
        ) { updateStage in
            updateStage(.downloading)
            try await self.svnClient.export(
                url: request.sourceURL,
                to: destinationURL,
                revision: request.revision,
                overwrite: overwrite,
                options: request.options
            )
            updateStage(.finalizing)
        }
        noticeText = "下载完成 · \(destinationURL.path)"
        onChange?()
    }

    func download(_ items: [BrowserBatchDownloadItem], to directoryURL: URL) async throws {
        guard !items.isEmpty else { return }
        let totalBytes = items.compactMap(\.request.byteSize).reduce(0, +)
        let sizeText = totalBytes > 0
            ? ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            : "大小未知"
        try await performTransfer(
            kind: .download,
            title: "下载 \(items.count) 项",
            detail: "\(sizeText) · 保存到 \(directoryURL.lastPathComponent)",
            cancellable: true,
            outputURL: directoryURL,
            retryRequest: nil
        ) { updateStage in
            updateStage(.downloading)
            var completedCount = 0
            var failures: [String] = []
            for item in items {
                try Task.checkCancellation()
                do {
                    try await self.svnClient.export(
                        url: item.request.sourceURL,
                        to: item.destinationURL,
                        revision: item.request.revision,
                        overwrite: item.overwrite,
                        options: item.request.options
                    )
                    completedCount += 1
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failures.append(item.request.displayName)
                }
            }
            guard failures.isEmpty else {
                throw BrowserBatchDownloadFailure(completedCount: completedCount, failures: failures)
            }
            updateStage(.finalizing)
        }
        noticeText = "已下载 \(items.count) 项 · \(directoryURL.path)"
        onChange?()
    }

    func localURLForOpening(_ row: BrowserRow) async throws -> URL {
        guard let session, row.kind == .file else { throw SVNClientError.unsupportedOperation }
        let revision = try await effectiveRevision(for: row, session: session)
        if let existing = openDocuments.values.first(where: {
            $0.manifest.profileID == session.profileID && $0.manifest.sourceURL == row.url
        }), FileManager.default.fileExists(atPath: existing.localURL.path) {
            let isModified = (try? openDocumentFingerprint(at: existing.localURL)) != existing.manifest.baseline
            if isModified || existing.manifest.expectedRevision == revision {
                return existing.localURL
            }
            removeOpenDocument(id: existing.manifest.id)
        }
        let snapshot = try await localSnapshotURL(for: row, effectiveRevision: revision, session: session)
        return try editableCopy(
            of: snapshot,
            sourceURL: row.url,
            profileID: session.profileID,
            expectedRevision: revision,
            options: session.options
        )
    }

    func localSnapshotURL(for row: BrowserRow) async throws -> URL {
        guard let session, row.kind == .file else { throw SVNClientError.unsupportedOperation }
        let effectiveRevision = try await effectiveRevision(for: row, session: session)
        return try await localSnapshotURL(for: row, effectiveRevision: effectiveRevision, session: session)
    }

    private func effectiveRevision(for row: BrowserRow, session: RepositorySession) async throws -> Int {
        if !isShowingSearchResults, let revision = row.revision { return revision }
        let liveInfo = try await svnClient.info(url: row.url, options: session.options)
        return liveInfo.lastChangedRevision ?? liveInfo.revision
    }

    private func localSnapshotURL(
        for row: BrowserRow,
        effectiveRevision: Int,
        session: RepositorySession
    ) async throws -> URL {
        let cacheURL = try snapshotCacheURL(
            profileID: session.profileID,
            revision: effectiveRevision,
            itemURL: itemURL(for: row)
        )
        if !FileManager.default.fileExists(atPath: cacheURL.path) {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try await download(
                BrowserDownloadRequest(
                    sourceURL: row.url,
                    displayName: row.name,
                    byteSize: row.byteSize,
                    revision: effectiveRevision,
                    options: session.options
                ),
                to: cacheURL,
                overwrite: true
            )
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: cacheURL.path)
        return cacheURL
    }

    func refreshOpenDocumentChanges() {
        onChange?()
    }

    func uploadOpenDocumentChanges(id: UUID, message: String) async throws -> SVNWriteResult {
        guard var document = openDocuments[id],
              FileManager.default.fileExists(atPath: document.localURL.path) else {
            throw SVNClientError.invalidLocalFile("本地编辑副本已经不存在")
        }
        if document.options == nil,
           let session, session.profileID == document.manifest.profileID {
            document.options = session.options
        }
        guard let options = document.options else {
            throw SVNClientError.invalidLocalFile("请先连接该文件所属的 SVN 服务器，再上传修改")
        }
        let currentFingerprint = try openDocumentFingerprint(at: document.localURL)
        guard currentFingerprint != document.manifest.baseline else {
            throw SVNClientError.invalidLocalFile("文件内容没有新的修改")
        }
        let expectedRevision: Int
        if let recordedRevision = document.manifest.expectedRevision {
            expectedRevision = recordedRevision
        } else {
            let info = try await svnClient.info(url: document.manifest.sourceURL, options: options)
            expectedRevision = info.lastChangedRevision ?? info.revision
        }
        let profileID = document.manifest.profileID
        let generation = session?.profileID == profileID ? sessionGeneration : UUID()
        let stagedBaselineURL = document.localURL.deletingLastPathComponent()
            .appendingPathComponent(".svnclient-baseline-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: document.localURL, to: stagedBaselineURL)
        let result: SVNWriteResult
        do {
            result = try await performTransfer(
                kind: .replace,
                title: "上传 \(document.manifest.displayName) 的修改",
                detail: "检查远端 r\(expectedRevision) 后创建新版本",
                cancellable: true,
                outputURL: nil,
                retryRequest: nil
            ) { updateStage in
                updateStage(.checkingAndCommitting)
                return try await self.svnClient.replace(
                    localFileURL: stagedBaselineURL,
                    targetURL: document.manifest.sourceURL,
                    expectedRevision: expectedRevision,
                    message: message,
                    options: options
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: stagedBaselineURL)
            throw error
        }
        document.manifest.expectedRevision = result.revision
        document.manifest.baseline = currentFingerprint
        let baselineURL = openDocumentBaselineURL(for: document)
        try? FileManager.default.removeItem(at: baselineURL)
        try? FileManager.default.moveItem(at: stagedBaselineURL, to: baselineURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: baselineURL.path)
        try? writeOpenDocumentManifest(document)
        openDocuments[id] = document
        await finishCommittedWrite(
            "已上传“\(document.manifest.displayName)”的修改",
            result: result,
            profileID: profileID,
            generation: generation
        )
        onChange?()
        return result
    }

    func history(for row: BrowserRow, limit: Int = 100) async throws -> BrowserFileHistory {
        guard let session, row.kind == .file else { throw SVNClientError.unsupportedOperation }
        return try await performActivity("正在读取“\(row.name)”的历史…", cancellable: true) {
            let info = try await self.svnClient.info(url: row.url, options: session.options)
            guard info.kind == .file else { throw SVNClientError.unsupportedOperation }
            let entries = try await self.svnClient.log(
                url: row.url,
                pegRevision: info.revision,
                limit: limit,
                options: session.options
            )
            return BrowserFileHistory(
                profileID: session.profileID,
                sourceURL: row.url,
                displayName: row.name,
                currentRevision: info.lastChangedRevision ?? info.revision,
                pegRevision: info.revision,
                entries: entries.sorted { $0.revision > $1.revision },
                options: session.options
            )
        }
    }

    func download(
        history: BrowserFileHistory,
        revision: Int,
        to destinationURL: URL,
        overwrite: Bool
    ) async throws {
        guard history.entries.contains(where: { $0.revision == revision }) else {
            throw SVNClientError.unsupportedOperation
        }
        try await downloadHistoricalVersion(
            BrowserHistoricalDownloadRequest(
                sourceURL: history.sourceURL,
                displayName: history.displayName,
                pegRevision: history.pegRevision,
                revision: revision,
                options: history.options
            ),
            to: destinationURL,
            overwrite: overwrite
        )
    }

    private func downloadHistoricalVersion(
        _ request: BrowserHistoricalDownloadRequest,
        to destinationURL: URL,
        overwrite: Bool
    ) async throws {
        try await performTransfer(
            kind: .download,
            title: "下载 \(request.displayName) 的 r\(request.revision)",
            detail: "历史版本 · 保存为 \(destinationURL.lastPathComponent)",
            cancellable: true,
            outputURL: destinationURL,
            retryRequest: .historicalDownload(request, destinationURL: destinationURL, overwrite: overwrite)
        ) { updateStage in
            updateStage(.downloading)
            try await self.svnClient.exportHistoricalVersion(
                url: request.sourceURL,
                pegRevision: request.pegRevision,
                revision: request.revision,
                to: destinationURL,
                overwrite: overwrite,
                options: request.options
            )
            updateStage(.finalizing)
        }
        noticeText = "历史版本 r\(request.revision) 下载完成 · \(destinationURL.path)"
        onChange?()
    }

    func localURLForOpening(history: BrowserFileHistory, revision: Int) async throws -> URL {
        try await localSnapshotURL(history: history, revision: revision)
    }

    func localSnapshotURL(history: BrowserFileHistory, revision: Int) async throws -> URL {
        guard history.entries.contains(where: { $0.revision == revision }) else {
            throw SVNClientError.unsupportedOperation
        }
        let cacheURL = try snapshotCacheURL(
            profileID: history.profileID,
            revision: revision,
            itemURL: history.sourceURL
        )
        if !FileManager.default.fileExists(atPath: cacheURL.path) {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try await download(history: history, revision: revision, to: cacheURL, overwrite: true)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: cacheURL.path)
        return cacheURL
    }

    func restore(
        history: BrowserFileHistory,
        revision: Int,
        message: String
    ) async throws -> SVNWriteResult {
        let generation = sessionGeneration
        guard revision != history.currentRevision else { throw SVNClientError.alreadyCurrentRevision }
        guard history.entries.contains(where: { $0.revision == revision }) else {
            throw SVNClientError.unsupportedOperation
        }
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SVNClient-Restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let historicalFileURL = temporaryDirectory.appendingPathComponent(history.displayName)
        let result = try await performTransfer(
            kind: .replace,
            title: "恢复 \(history.displayName) 至 r\(revision)",
            detail: "基于当前 r\(history.currentRevision) 创建新版本",
            cancellable: true,
            outputURL: nil,
            retryRequest: nil
        ) { updateStage in
            updateStage(.downloading)
            try await self.svnClient.exportHistoricalVersion(
                url: history.sourceURL,
                pegRevision: history.pegRevision,
                revision: revision,
                to: historicalFileURL,
                overwrite: false,
                options: history.options
            )
            updateStage(.checkingAndCommitting)
            return try await self.svnClient.replace(
                localFileURL: historicalFileURL,
                targetURL: history.sourceURL,
                expectedRevision: history.currentRevision,
                message: message,
                options: history.options
            )
        }
        await finishCommittedWrite("已恢复 r\(revision) 的内容", result: result,
            profileID: history.profileID, generation: generation)
        return result
    }

    func toggleFavorite(_ row: BrowserRow) async throws -> Bool {
        let newValue = !isFavorite(row)
        _ = try await setFavorites([row], isFavorite: newValue)
        return newValue
    }

    @discardableResult
    func setFavorites(_ rows: [BrowserRow], isFavorite: Bool) async throws -> Int {
        guard let session, let metadataService else { throw SVNClientError.unsupportedOperation }
        guard !rows.isEmpty else { return 0 }
        let changedCount = try await metadataService.setFavorites(
            profileID: session.profileID,
            candidates: rows.map { row in
                RepositoryFavoriteCandidate(
                    url: row.url,
                    name: row.name,
                    kind: row.kind == .directory ? .directory : .file,
                    revision: row.revision
                )
            },
            isFavorite: isFavorite
        )
        for row in rows {
            if isFavorite {
                favoriteURLKeys.insert(row.url.absoluteString)
            } else {
                favoriteURLKeys.remove(row.url.absoluteString)
            }
        }
        if changedCount > 0 {
            noticeText = isFavorite
                ? (changedCount == 1 ? "已添加到收藏" : "已添加 \(changedCount) 项到收藏")
                : (changedCount == 1 ? "已从收藏移除" : "已从收藏移除 \(changedCount) 项")
        }
        onMetadataChanged?()
        onChange?()
        return changedCount
    }

    func isFavorite(_ row: BrowserRow) -> Bool {
        favoriteURLKeys.contains(row.url.absoluteString)
    }

    func reloadFavorites() async throws {
        guard let session, let metadataService else {
            favoriteURLKeys = []
            return
        }
        let generation = sessionGeneration
        let keys = Set(
            try await metadataService.favorites()
                .filter { $0.profileID == session.profileID }
                .map { $0.url.absoluteString }
        )
        guard generation == sessionGeneration else { return }
        favoriteURLKeys = keys
    }

    private func refreshSearchIndex(rootURL: URL) async throws {
        guard let session, let metadataService else { throw SVNClientError.unsupportedOperation }
        let generation = sessionGeneration
        let key = SearchIndexRefreshKey(
            profileID: session.profileID,
            rootURL: rootURL,
            generation: generation
        )
        if let sharedRefresh = searchIndexRefreshTasks[key] {
            try await sharedRefresh.task.value
            try Task.checkCancellation()
            return
        }

        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await self.rebuildSearchIndex(
                rootURL: rootURL,
                session: session,
                metadataService: metadataService,
                generation: generation
            )
        }
        searchIndexRefreshTasks[key] = SharedSearchIndexRefresh(id: id, task: task)
        defer {
            if searchIndexRefreshTasks[key]?.id == id {
                searchIndexRefreshTasks.removeValue(forKey: key)
            }
        }
        try await task.value
        try Task.checkCancellation()
    }

    private func rebuildSearchIndex(
        rootURL: URL,
        session: RepositorySession,
        metadataService: RepositoryMetadataService,
        generation: UUID
    ) async throws {
        let entries = try await performActivity("正在更新文件名索引…", cancellable: true) {
            try await self.svnClient.listRecursively(url: rootURL, options: session.options)
        }
        try Task.checkCancellation()
        guard generation == sessionGeneration else { throw CancellationError() }
        let indexedEntries = entries.map { entry -> SearchIndexEntry in
            let components = entry.name.split(separator: "/").map(String.init)
            let url = components.enumerated().reduce(rootURL) { partial, pair in
                let isDirectory = pair.offset < components.count - 1 || entry.kind == .directory
                return partial.appendingPathComponent(pair.element, isDirectory: isDirectory)
            }
            return SearchIndexEntry(
                profileID: session.profileID,
                rootURL: rootURL,
                url: url,
                name: components.last ?? entry.name,
                kind: SavedRepositoryItemKind(entry.kind),
                size: entry.size,
                revision: entry.revision,
                author: entry.author,
                modifiedAt: entry.updatedAt
            )
        }
        let indexedAt = Date()
        try await metadataService.replaceSearchIndex(
            profileID: session.profileID,
            rootURL: rootURL,
            entries: indexedEntries,
            indexedAt: indexedAt
        )
        try Task.checkCancellation()
        guard generation == sessionGeneration else { throw CancellationError() }
        if currentURL == rootURL,
           let rootSnapshot = try? await metadataService.directoryCache(profileID: session.profileID, url: rootURL) {
            browsingRows = rootSnapshot.entries.map { BrowserRow(entry: $0, parentURL: rootURL) }
            directoryCachedAt = rootSnapshot.cachedAt
            onDirectoryCacheRefreshed?(session.profileID, rootURL, rootSnapshot)
        }
        searchIndexedAt = indexedAt
        noticeText = "索引更新完成 · \(indexedEntries.count) 项"
        onChange?()
    }

    func search(query: String, refreshIfMissing: Bool = true) async throws {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            clearSearch()
            return
        }
        guard let session, let metadataService, let directoryURL = currentURL else { throw SVNClientError.unsupportedOperation }
        let requestID = UUID()
        let generation = sessionGeneration
        searchRequestID = requestID
        searchQuery = normalizedQuery
        var results = try await metadataService.search(
            profileID: session.profileID,
            rootURL: directoryURL,
            directoryURL: nil,
            query: normalizedQuery
        )
        try checkSearchRequest(requestID, generation: generation)
        let indexIsExpired = results.indexedAt.map {
            Date().timeIntervalSince($0) >= DirectoryCacheSnapshot.timeToLive
        } ?? true
        if indexIsExpired, refreshIfMissing {
            try await refreshSearchIndex(rootURL: directoryURL)
            try checkSearchRequest(requestID, generation: generation)
            results = try await metadataService.search(
                profileID: session.profileID,
                rootURL: directoryURL,
                directoryURL: nil,
                query: normalizedQuery
            )
        }
        try checkSearchRequest(requestID, generation: generation)
        rows = results.entries.map(BrowserRow.init(searchEntry:))
        isShowingSearchResults = true
        searchIndexedAt = results.indexedAt
        noticeText = nil
        onChange?()
    }

    private func checkSearchRequest(_ requestID: UUID, generation: UUID) throws {
        try Task.checkCancellation()
        guard requestID == searchRequestID, generation == sessionGeneration else { throw CancellationError() }
    }

    func clearSearch() {
        cancelSearchIndexRefreshTasks()
        endSearchMode(restoreRows: true)
        onChange?()
    }

    func cancelSearchIndexRefresh() {
        cancelSearchIndexRefreshTasks()
    }

    func createDirectory(name: String, in directoryURL: URL? = nil, message: String) async throws -> SVNWriteResult {
        guard let session, let currentURL else { throw SVNClientError.unsupportedOperation }
        let generation = sessionGeneration
        let targetDirectoryURL = directoryURL ?? currentURL
        let result = try await performActivity("正在新建文件夹…") {
            try await self.svnClient.makeDirectory(
                url: targetDirectoryURL.appendingPathComponent(name, isDirectory: true),
                message: message,
                options: session.options
            )
        }
        await finishCommittedWrite("文件夹已创建", result: result,
            profileID: session.profileID, generation: generation)
        return result
    }

    func rename(_ row: BrowserRow, to name: String, message: String) async throws -> SVNWriteResult {
        guard let session, currentURL != nil else { throw SVNClientError.unsupportedOperation }
        let generation = sessionGeneration
        let sourceURL = itemURL(for: row)
        let destinationURL = sourceURL.deletingLastPathComponent()
            .appendingPathComponent(name, isDirectory: row.kind == .directory)
        let result = try await performActivity("正在重命名“\(row.name)”…") {
            try await self.svnClient.move(
                from: sourceURL,
                to: destinationURL,
                message: message,
                options: session.options
            )
        }
        await finishCommittedWrite("重命名完成", result: result,
            profileID: session.profileID, generation: generation, updatesMetadata: true) {
            try await self.metadataService?.movePaths(profileID: session.profileID, from: sourceURL, to: destinationURL)
        }
        return result
    }

    func delete(_ row: BrowserRow, message: String) async throws -> SVNWriteResult {
        try await delete([row], message: message)
    }

    func delete(_ rows: [BrowserRow], message: String) async throws -> SVNWriteResult {
        guard let session else { throw SVNClientError.unsupportedOperation }
        guard !rows.isEmpty else { throw SVNClientError.unsupportedOperation }
        let generation = sessionGeneration
        let deletedURLs = rows.map(\.url)
        let activity = rows.count == 1 ? "正在删除“\(rows[0].name)”…" : "正在删除 \(rows.count) 项…"
        let result = try await performActivity(activity) {
            try await self.svnClient.delete(
                urls: deletedURLs,
                message: message,
                options: session.options
            )
        }
        await finishCommittedWrite(rows.count == 1 ? "删除完成" : "已删除 \(rows.count) 项", result: result,
            profileID: session.profileID, generation: generation, updatesMetadata: true) {
            for deletedURL in deletedURLs {
                try await self.metadataService?.markFavoritesUnavailable(profileID: session.profileID, atOrBelow: deletedURL)
            }
        }
        return result
    }

    func upload(files: [URL], to directoryURL: URL? = nil, message: String) async throws -> SVNWriteResult {
        guard let session, let currentURL else { throw SVNClientError.unsupportedOperation }
        let generation = sessionGeneration
        let targetDirectoryURL = directoryURL ?? currentURL
        let existingNames: Set<String> = targetDirectoryURL == currentURL ? Set(rows.map(\.name)) : []
        if let conflict = files.first(where: { existingNames.contains($0.lastPathComponent) }) {
            throw SVNClientError.commandFailed(SVNCommandFailure(
                operation: "upload",
                exitStatus: 1,
                standardOutput: "",
                standardError: "already exists: \(conflict.lastPathComponent)"
            ))
        }
        var fileCount = 0
        var directoryCount = 0
        var totalFileBytes: Int64 = 0
        for url in files {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                directoryCount += 1
            } else {
                fileCount += 1
                totalFileBytes += Int64(values?.fileSize ?? 0)
            }
        }
        var detailParts: [String] = []
        if fileCount > 0 {
            detailParts.append("\(fileCount) 个文件 · \(ByteCountFormatter.string(fromByteCount: totalFileBytes, countStyle: .file))")
        }
        if directoryCount > 0 { detailParts.append("\(directoryCount) 个文件夹") }
        let result = try await performTransfer(
            kind: .upload,
            title: "上传 \(files.count) 个项目",
            detail: detailParts.joined(separator: " · "),
            cancellable: true,
            outputURL: nil,
            retryRequest: nil
        ) { updateStage in
            updateStage(.uploadingAndCommitting)
            return try await self.svnClient.upload(
                files: files,
                to: targetDirectoryURL,
                message: message,
                options: session.options
            )
        }
        await finishCommittedWrite("上传完成", result: result,
            profileID: session.profileID, generation: generation)
        return result
    }

    func replace(_ row: BrowserRow, with localFileURL: URL, message: String) async throws -> SVNWriteResult {
        guard let session, let revision = row.revision else { throw SVNClientError.remoteChanged }
        let generation = sessionGeneration
        let localSize = (try? localFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "大小未知"
        let result = try await performTransfer(
            kind: .replace,
            title: "替换 \(row.name)",
            detail: localSize,
            cancellable: true,
            outputURL: nil,
            retryRequest: nil
        ) { updateStage in
            updateStage(.checkingAndCommitting)
            return try await self.svnClient.replace(
                localFileURL: localFileURL,
                targetURL: self.itemURL(for: row),
                expectedRevision: revision,
                message: message,
                options: session.options
            )
        }
        await finishCommittedWrite("替换完成", result: result,
            profileID: session.profileID, generation: generation)
        return result
    }

    func info(for row: BrowserRow) async throws -> SVNItemInfo {
        guard let session else { throw SVNClientError.unsupportedOperation }
        return try await performActivity("正在读取文件信息…") {
            try await self.svnClient.info(url: self.itemURL(for: row), options: session.options)
        }
    }

    func displayPath(for row: BrowserRow) -> String {
        guard let session else { return row.name }
        let baseComponents = session.baseURL.pathComponents.filter { $0 != "/" }
        let rowComponents = row.url.pathComponents.filter { $0 != "/" }
        let relative = rowComponents.dropFirst(min(baseComponents.count, rowComponents.count))
            .map { $0.removingPercentEncoding ?? $0 }
        return ([session.displayName] + relative).joined(separator: " / ")
    }

    private enum DirectoryLoadPolicy: Equatable {
        case preferCache
        case reload
    }

    private func load(url: URL, clearRows: Bool, policy: DirectoryLoadPolicy, requestID: UUID = UUID()) async throws {
        guard let session else { return }
        cancelBackgroundDirectoryTasks()
        cancelSearchIndexRefreshTasks()
        endSearchMode(restoreRows: true)
        let generation = sessionGeneration
        directoryRequestID = requestID
        activityID = requestID
        activityTransferID = nil
        let previousRows = isShowingSearchResults ? rows : browsingRows
        let previousURL = currentURL
        let previousState: State = previousURL.map(State.loaded) ?? .disconnected
        state = .loading
        isBusy = true
        isCancellable = true
        activityText = "正在读取目录…"
        noticeText = nil
        if clearRows { rows = [] }
        onChange?()

        do {
            if policy == .preferCache,
               let snapshot = try? await metadataService?.directoryCache(profileID: session.profileID, url: url) {
                try checkDirectoryRequest(requestID, generation: generation)
                applyDirectoryEntries(snapshot.entries, url: url, cachedAt: snapshot.cachedAt)
                if snapshot.isExpired() { scheduleDirectoryRevalidation(url: url, session: session, pageRequestID: requestID) }
                return
            }
            try checkDirectoryRequest(requestID, generation: generation)
            let entries = try await svnClient.list(url: url, options: session.options)
            try checkDirectoryRequest(requestID, generation: generation)
            let cachedAt = Date()
            try? await metadataService?.replaceDirectoryCache(
                profileID: session.profileID,
                url: url,
                entries: entries,
                cachedAt: cachedAt
            )
            try checkDirectoryRequest(requestID, generation: generation)
            applyDirectoryEntries(entries, url: url, cachedAt: cachedAt)
        } catch is CancellationError {
            guard requestID == directoryRequestID, generation == sessionGeneration else {
                throw CancellationError()
            }
            rows = previousRows
            currentURL = previousURL
            state = previousState
            isBusy = false
            isCancellable = false
            activityText = nil
            onChange?()
            throw CancellationError()
        } catch {
            guard requestID == directoryRequestID, generation == sessionGeneration else {
                throw CancellationError()
            }
            state = .failed(error.localizedDescription)
            isBusy = false
            isCancellable = false
            activityText = nil
            onChange?()
            throw error
        }
    }

    private func checkDirectoryRequest(_ requestID: UUID, generation: UUID) throws {
        try Task.checkCancellation()
        guard requestID == directoryRequestID, generation == sessionGeneration else {
            throw CancellationError()
        }
    }

    private func cancelBackgroundDirectoryTasks() {
        backgroundDirectoryTasks.values.forEach { $0.task.cancel() }
        backgroundDirectoryTasks.removeAll()
    }

    private func cancelSearchIndexRefreshTasks() {
        searchIndexRefreshTasks.values.forEach { $0.task.cancel() }
        searchIndexRefreshTasks.removeAll()
    }

    private func scheduleDirectoryRevalidation(url: URL, session: RepositorySession, pageRequestID: UUID?) {
        guard let metadataService, backgroundDirectoryTasks[url] == nil else { return }
        let id = UUID()
        let generation = sessionGeneration
        let treeGeneration = directoryTreeGeneration
        let svnClient = svnClient
        backgroundDirectoryTasks[url] = (id, Task { @MainActor [weak self] in
            defer {
                if self?.backgroundDirectoryTasks[url]?.id == id { self?.backgroundDirectoryTasks.removeValue(forKey: url) }
            }
            do {
                let snapshot = try await metadataService.refreshDirectoryCache(profileID: session.profileID, url: url) {
                    try await svnClient.list(url: url, options: session.options)
                }
                try Task.checkCancellation()
                guard let self, self.sessionGeneration == generation,
                      self.directoryTreeGeneration == treeGeneration else { return }
                if let pageRequestID {
                    guard self.directoryRequestID == pageRequestID, self.currentURL == url,
                          !self.isShowingSearchResults, !self.isBusy else { return }
                    self.applyDirectoryEntries(snapshot.entries, url: url, cachedAt: snapshot.cachedAt)
                } else {
                    self.onTreeDirectoryRefreshed?(url, snapshot.entries.map { BrowserRow(entry: $0, parentURL: url) })
                }
                self.onDirectoryCacheRefreshed?(session.profileID, url, snapshot)
            } catch is CancellationError {
                // Navigation and explicit refresh take precedence over a stale-cache read.
            } catch {
                guard let self, !Task.isCancelled, self.sessionGeneration == generation,
                      self.directoryTreeGeneration == treeGeneration,
                      let pageRequestID, self.directoryRequestID == pageRequestID,
                      !self.isShowingSearchResults, !self.isBusy else { return }
                self.noticeText = "正在显示缓存 · 后台刷新失败，请手动刷新：" + error.localizedDescription
                self.onChange?()
            }
        })
    }

    private func applyDirectoryEntries(_ entries: [SVNListEntry], url: URL, cachedAt: Date) {
        rows = entries.map { BrowserRow(entry: $0, parentURL: url) }
        browsingRows = rows
        isShowingSearchResults = false
        currentURL = url
        directoryCachedAt = cachedAt
        state = .loaded(url)
        isBusy = false
        isCancellable = false
        activityText = nil
        noticeText = nil
        onChange?()
    }

    private func finishCommittedWrite(
        _ message: String,
        result: SVNWriteResult,
        profileID: UUID,
        generation: UUID,
        updatesMetadata: Bool = false,
        metadataUpdate: () async throws -> Void = {}
    ) async {
        // A successful commit cannot become a failed write because a subsequent local/read operation fails.
        let previousDirectoryRequestID = directoryRequestID
        var warnings: [String] = []
        do { try await metadataUpdate() } catch { warnings.append("收藏同步失败") }
        do { try await metadataService?.clearRepositoryCache(profileID: profileID) }
        catch { warnings.append("本地缓存清理失败") }
        if updatesMetadata { onMetadataChanged?() }
        guard generation == sessionGeneration, session?.profileID == profileID else { return }
        directoryTreeGeneration += 1
        if updatesMetadata {
            do { try await reloadFavorites() } catch { warnings.append("收藏状态读取失败") }
        }
        guard generation == sessionGeneration else { return }
        // Local metadata work must not supersede navigation started after this commit.
        guard previousDirectoryRequestID == directoryRequestID else { return }
        if let currentURL {
            let refreshRequestID = UUID()
            do {
                try await load(url: currentURL, clearRows: false, policy: .reload, requestID: refreshRequestID)
                onRepositoryChanged?(profileID, currentURL)
            }
            catch {
                guard generation == sessionGeneration, refreshRequestID == directoryRequestID else { return }
                // Do not leave pre-commit rows actionable after a failed refresh.
                rows = []
                browsingRows = []
                warnings.append("目录刷新失败，请手动刷新；不要重复提交")
            }
        }
        guard generation == sessionGeneration else { return }
        showWriteSuccess(message, result: result)
        if !warnings.isEmpty {
            noticeText = (noticeText ?? message) + " · 已提交成功，但" + warnings.joined(separator: "；")
            onChange?()
        }
    }

    private func performActivity<Result: Sendable>(
        _ text: String,
        cancellable: Bool = false,
        transferID: UUID? = nil,
        operation: () async throws -> Result
    ) async throws -> Result {
        let id = UUID()
        activityID = id
        activityTransferID = transferID
        isBusy = true
        isCancellable = cancellable
        activityText = text
        noticeText = nil
        onChange?()
        defer {
            if activityID == id {
                isBusy = false
                isCancellable = false
                activityText = nil
                activityTransferID = nil
                onChange?()
            }
        }
        return try await operation()
    }

    private func performTransfer<Result: Sendable>(
        kind: BrowserTransfer.Kind,
        title: String,
        detail: String,
        cancellable: Bool,
        outputURL: URL?,
        retryRequest: BrowserTransfer.RetryRequest?,
        operation: @escaping @MainActor (_ updateStage: @MainActor (BrowserTransfer.Stage) -> Void) async throws -> Result
    ) async throws -> Result {
        let id = UUID()
        transfers.insert(
            BrowserTransfer(
                id: id,
                kind: kind,
                title: title,
                detail: detail,
                state: .running,
                stage: .preparing,
                outputURL: outputURL,
                retryRequest: retryRequest,
                isCancellable: cancellable,
                startedAt: .now,
                finishedAt: nil
            ),
            at: 0
        )
        trimTransferHistory()
        onChange?()
        let task = Task { @MainActor in
            try await operation { [weak self] stage in
                self?.updateTransferStage(id: id, stage: stage)
            }
        }
        transferCancellations[id] = { task.cancel() }
        defer { transferCancellations.removeValue(forKey: id) }
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            finishTransfer(id: id, state: .completed)
            return result
        } catch is CancellationError {
            finishTransfer(id: id, state: .cancelled)
            if kind.isWrite {
                noticeText = "写入任务已停止 · SVN 提交状态可能未知，请刷新仓库确认"
                onChange?()
            }
            throw CancellationError()
        } catch {
            finishTransfer(id: id, state: .failed(error.localizedDescription))
            throw error
        }
    }

    func cancelTransfer(id: UUID) {
        guard transfers.first(where: { $0.id == id })?.canCancel == true else { return }
        transferCancellations[id]?()
    }

    func clearFinishedTransfers() {
        transfers.removeAll { $0.state != .running }
        onChange?()
    }

    func retryTransfer(id: UUID) async throws {
        guard let index = transfers.firstIndex(where: { $0.id == id && $0.canRetry }),
              let retryRequest = transfers[index].retryRequest else {
            throw SVNClientError.unsupportedOperation
        }
        transfers.remove(at: index)
        onChange?()
        switch retryRequest {
        case let .download(request, destinationURL, overwrite):
            try await download(request, to: destinationURL, overwrite: overwrite)
        case let .historicalDownload(request, destinationURL, overwrite):
            try await downloadHistoricalVersion(request, to: destinationURL, overwrite: overwrite)
        }
    }

    private func updateTransferStage(id: UUID, stage: BrowserTransfer.Stage) {
        guard let index = transfers.firstIndex(where: { $0.id == id }), transfers[index].state == .running else {
            return
        }
        transfers[index].stage = stage
        if activityTransferID == id {
            activityText = "\(transfers[index].title) · \(stage.text)"
        }
        onChange?()
    }

    private func finishTransfer(id: UUID, state: BrowserTransfer.State) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].state = state
        transfers[index].finishedAt = .now
        trimTransferHistory()
        onChange?()
    }

    private func trimTransferHistory() {
        let active = transfers.filter { $0.state == .running }
        let finished = transfers.filter { $0.state != .running }.prefix(20)
        transfers = active + finished
    }

    private func showWriteSuccess(_ message: String, result: SVNWriteResult) {
        noticeText = result.revision.map { "\(message) · r\($0)" } ?? message
        onChange?()
    }

    private func endSearchMode(restoreRows: Bool) {
        searchRequestID = UUID()
        if restoreRows { rows = browsingRows }
        isShowingSearchResults = false
        searchQuery = ""
        searchIndexedAt = nil
    }

    private func managedCacheRoot() throws -> URL {
        if let cacheRootURL { return cacheRootURL }
        return try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("SVNClient", isDirectory: true)
    }

    private func snapshotCacheURL(profileID: UUID, revision: Int?, itemURL: URL) throws -> URL {
        // A new namespace deliberately excludes legacy OpenCache files, which may have been edited.
        let cacheRoot = try managedCacheRoot().appendingPathComponent("RevisionSnapshots-v1", isDirectory: true)
        let revision = revision.map(String.init) ?? "HEAD"
        let key = SHA256.hash(data: Data(itemURL.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheRoot.appendingPathComponent(profileID.uuidString)
            .appendingPathComponent(revision).appendingPathComponent(key)
            .appendingPathComponent(itemURL.lastPathComponent)
    }

    private func editableCopy(
        of snapshotURL: URL,
        sourceURL: URL,
        profileID: UUID,
        expectedRevision: Int,
        options: SVNRequestOptions
    ) throws -> URL {
        let directory = try managedCacheRoot().appendingPathComponent("OpenDocuments", isDirectory: true)
            .appendingPathComponent(openDocumentSessionID.uuidString, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copyURL = directory.appendingPathComponent(snapshotURL.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: snapshotURL, to: copyURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copyURL.path)
            let manifest = OpenDocumentManifest(
                id: UUID(),
                profileID: profileID,
                sourceURL: sourceURL,
                displayName: snapshotURL.lastPathComponent,
                expectedRevision: expectedRevision,
                baseline: try openDocumentFingerprint(at: copyURL),
                createdAt: .now
            )
            let document = TrackedOpenDocument(manifest: manifest, localURL: copyURL, options: options)
            let baselineURL = openDocumentBaselineURL(for: document)
            try FileManager.default.copyItem(at: snapshotURL, to: baselineURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: baselineURL.path)
            try writeOpenDocumentManifest(document)
            openDocuments[manifest.id] = document
            return copyURL
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func cleanupOpenDocumentCopies() {
        for id in Array(openDocuments.keys) {
            guard let document = openDocuments[id],
                  let fingerprint = try? openDocumentFingerprint(at: document.localURL) else {
                openDocuments.removeValue(forKey: id)
                continue
            }
            guard fingerprint == document.manifest.baseline else { continue }
            removeOpenDocument(id: id)
        }
        if let sessionURL = try? openDocumentSessionURL() {
            removeOpenDocumentsRootIfEmpty(sessionURL)
            removeOpenDocumentsRootIfEmpty(sessionURL.deletingLastPathComponent())
        }
    }

    private func cleanupAbandonedOpenDocumentCopies(now: Date = .now) throws {
        let root = try openDocumentsRootURL()
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .creationDateKey, .isDirectoryKey]
        let sessionDirectories = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        let expirationDate = now.addingTimeInterval(-Self.abandonedOpenDocumentRetention)
        for sessionDirectory in sessionDirectories where sessionDirectory.lastPathComponent != openDocumentSessionID.uuidString {
            let copyDirectories = (try? FileManager.default.contentsOfDirectory(
                at: sessionDirectory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )) ?? []
            if copyDirectories.isEmpty {
                let values = try? sessionDirectory.resourceValues(forKeys: keys)
                if let modifiedAt = values?.contentModificationDate ?? values?.creationDate,
                   modifiedAt < expirationDate {
                    try? FileManager.default.removeItem(at: sessionDirectory)
                }
                continue
            }
            for directory in copyDirectories {
                let values = try? directory.resourceValues(forKeys: keys)
                guard values?.isDirectory == true,
                      let modifiedAt = values?.contentModificationDate ?? values?.creationDate,
                      modifiedAt < expirationDate else { continue }
                if let document = openDocuments.values.first(where: {
                    $0.localURL.deletingLastPathComponent() == directory
                }), let fingerprint = try? openDocumentFingerprint(at: document.localURL),
                   fingerprint != document.manifest.baseline {
                    continue
                }
                try? FileManager.default.removeItem(at: directory)
                openDocuments = openDocuments.filter {
                    $0.value.localURL.deletingLastPathComponent() != directory
                }
            }
            removeOpenDocumentsRootIfEmpty(sessionDirectory)
        }
        removeOpenDocumentsRootIfEmpty(root)
    }

    private func loadTrackedOpenDocuments() throws {
        let root = try openDocumentsRootURL()
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        )
        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.lastPathComponent == Self.openDocumentManifestName,
                  let data = try? Data(contentsOf: fileURL),
                  let manifest = try? JSONDecoder().decode(OpenDocumentManifest.self, from: data) else { continue }
            let localURL = fileURL.deletingLastPathComponent().appendingPathComponent(manifest.displayName)
            guard FileManager.default.fileExists(atPath: localURL.path) else { continue }
            openDocuments[manifest.id] = TrackedOpenDocument(
                manifest: manifest,
                localURL: localURL,
                options: nil
            )
        }
    }

    private func writeOpenDocumentManifest(_ document: TrackedOpenDocument) throws {
        let url = document.localURL.deletingLastPathComponent()
            .appendingPathComponent(Self.openDocumentManifestName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(document.manifest).write(to: url, options: .atomic)
    }

    private func openDocumentFingerprint(at url: URL) throws -> OpenDocumentFingerprint {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return OpenDocumentFingerprint(
            modifiedAt: attributes[.modificationDate] as? Date,
            byteSize: (attributes[.size] as? NSNumber)?.int64Value
        )
    }

    private func overwriteOpenDocument(at destinationURL: URL, withContentsOf sourceURL: URL) throws {
        // Keep the existing inode so resetting a document does not require replacing a file
        // that may still be open in Word or another editor.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destinationURL.path
        )
        let source = try FileHandle(forReadingFrom: sourceURL)
        defer { try? source.close() }
        let destination = try FileHandle(forWritingTo: destinationURL)
        defer { try? destination.close() }
        try destination.truncate(atOffset: 0)
        while let chunk = try source.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try destination.write(contentsOf: chunk)
        }
        try destination.synchronize()
    }

    private func modifiedDocument(for sourceURL: URL, profileID: UUID) -> TrackedOpenDocument? {
        openDocuments.values
            .filter { $0.manifest.profileID == profileID && $0.manifest.sourceURL == sourceURL }
            .filter { document in
                guard let fingerprint = try? openDocumentFingerprint(at: document.localURL) else { return false }
                return fingerprint != document.manifest.baseline
            }
            .max { lhs, rhs in
                lhs.manifest.createdAt < rhs.manifest.createdAt
            }
    }

    private func openDocumentBaselineURL(for document: TrackedOpenDocument) -> URL {
        document.localURL.deletingLastPathComponent()
            .appendingPathComponent(Self.openDocumentBaselineName)
    }

    private func removeOpenDocument(id: UUID) {
        guard let document = openDocuments.removeValue(forKey: id) else { return }
        let directory = document.localURL.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: directory)
        removeOpenDocumentsRootIfEmpty(directory.deletingLastPathComponent())
    }

    private func openDocumentsRootURL() throws -> URL {
        try managedCacheRoot().appendingPathComponent("OpenDocuments", isDirectory: true)
    }

    private func openDocumentSessionURL() throws -> URL {
        try openDocumentsRootURL().appendingPathComponent(openDocumentSessionID.uuidString, isDirectory: true)
    }

    private func removeOpenDocumentsRootIfEmpty(_ root: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: root.path), contents.isEmpty else { return }
        try? FileManager.default.removeItem(at: root)
    }

    var statusText: String {
        if let activityText { return activityText }
        if let noticeText { return noticeText }
        if isShowingSearchResults {
            let date = searchIndexedAt?.formatted(date: .abbreviated, time: .shortened) ?? "尚未建立"
            return "找到 \(rows.count) 项 · 索引更新于 \(date)"
        }
        switch state {
        case .disconnected:
            return "尚未连接仓库"
        case .loading:
            return "正在连接并读取目录…"
        case let .loaded(url):
            let updated = directoryCachedAt?.formatted(date: .abbreviated, time: .shortened) ?? "未知"
            return rows.isEmpty
                ? "这个文件夹是空的 · 缓存更新于 \(updated)"
                : "已连接 · \(url.host ?? session?.displayName ?? url.lastPathComponent) · \(rows.count) 项 · 缓存更新于 \(updated)"
        case let .failed(message):
            return "连接失败 · \(message)"
        }
    }
}

struct BrowserRow: Identifiable, Equatable, Sendable {
    enum Kind: Equatable { case file, directory }

    let id: String
    let name: String
    let size: String
    let modified: String
    let author: String
    let revisionText: String
    let kind: Kind
    let byteSize: Int64?
    let updatedAt: Date?
    let revision: Int?
    let url: URL
    let location: String

    init(entry: SVNListEntry, parentURL: URL) {
        name = entry.name
        size = entry.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
        modified = entry.updatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—"
        author = entry.author ?? "—"
        revisionText = entry.revision.map { "r\($0)" } ?? "—"
        kind = entry.kind == .directory ? .directory : .file
        byteSize = entry.size
        updatedAt = entry.updatedAt
        revision = entry.revision
        url = parentURL.appendingPathComponent(entry.name, isDirectory: entry.kind == .directory)
        location = ""
        id = url.absoluteString
    }

    init(searchEntry: SearchIndexEntry) {
        name = searchEntry.name
        size = searchEntry.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
        modified = searchEntry.modifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—"
        author = searchEntry.author ?? "—"
        revisionText = searchEntry.revision.map { "r\($0)" } ?? "—"
        kind = searchEntry.kind == .directory ? .directory : .file
        byteSize = searchEntry.size
        updatedAt = searchEntry.modifiedAt
        revision = searchEntry.revision
        url = searchEntry.url
        let rootPath = searchEntry.rootURL.path.hasSuffix("/")
            ? searchEntry.rootURL.path
            : searchEntry.rootURL.path + "/"
        let parentPath = searchEntry.url.deletingLastPathComponent().path
        location = String(parentPath.dropFirst(min(rootPath.count, parentPath.count)))
            .removingPercentEncoding ?? parentPath
        id = url.absoluteString
    }

    func value(for column: String) -> String {
        switch column {
        case "name": return name
        case "type": return kind == .directory ? "文件夹" : "文件"
        case "size": return size
        case "modified": return modified
        case "author": return author
        case "revision": return revisionText
        case "location": return location.isEmpty ? "—" : location
        default: return ""
        }
    }
}
