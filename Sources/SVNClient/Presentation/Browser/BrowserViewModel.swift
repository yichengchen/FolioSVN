import Foundation

struct RepositorySession: Sendable {
    let profileID: UUID
    let displayName: String
    let baseURL: URL
    let searchRootURL: URL
    let options: SVNRequestOptions
}

struct BrowserDownloadRequest: Sendable {
    let sourceURL: URL
    let displayName: String
    let byteSize: Int64?
    let revision: Int?
    let options: SVNRequestOptions
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

struct BrowserTransfer: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case download
        case upload
        case replace
    }

    enum State: Equatable, Sendable {
        case running
        case completed
        case cancelled
        case failed(String)
    }

    let id: UUID
    let kind: Kind
    let title: String
    let detail: String
    var state: State
    let startedAt: Date
    var finishedAt: Date?

    var stateText: String {
        switch state {
        case .running: return "进行中"
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
}

@MainActor
final class BrowserViewModel {
    enum SearchScope: Int, Sendable {
        case currentDirectory
        case configuredRoot
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

    private(set) var rows: [BrowserRow] = []
    private(set) var state: State = .disconnected
    private(set) var isBusy = false
    private(set) var isCancellable = false
    private(set) var activityText: String?
    private(set) var noticeText: String?
    private(set) var isShowingSearchResults = false
    private(set) var searchQuery = ""
    private(set) var searchScope: SearchScope = .configuredRoot
    private(set) var searchIndexedAt: Date?
    private(set) var directoryCachedAt: Date?
    private(set) var transfers: [BrowserTransfer] = []
    private(set) var session: RepositorySession?
    private(set) var currentURL: URL?
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    private var browsingRows: [BrowserRow] = []
    private var favoriteURLKeys: Set<String> = []
    private let svnClient: any SVNClient
    private let metadataService: RepositoryMetadataService?

    var activeTransferCount: Int {
        transfers.filter { $0.state == .running }.count
    }

    init(svnClient: any SVNClient, metadataService: RepositoryMetadataService? = nil) {
        self.svnClient = svnClient
        self.metadataService = metadataService
    }

    func connect(to url: URL, options: SVNRequestOptions = .anonymous) async throws {
        let name = url.host ?? url.lastPathComponent.removingPercentEncoding ?? "SVN 仓库"
        try await connect(session: RepositorySession(
            profileID: UUID(),
            displayName: name,
            baseURL: url,
            searchRootURL: url,
            options: options
        ))
    }

    func connect(profile: RepositoryProfile, password: String?, initialURL: URL? = nil) async throws {
        let connection = RepositoryConnection(profile: profile, password: password)
        try await connect(session: RepositorySession(
            profileID: profile.id,
            displayName: profile.displayName,
            baseURL: profile.baseURL,
            searchRootURL: profile.startURL,
            options: connection.requestOptions
        ), initialURL: initialURL ?? profile.startURL)
    }

    func connect(session: RepositorySession, initialURL: URL? = nil) async throws {
        self.session = session
        endSearchMode(restoreRows: false)
        backStack = []
        forwardStack = []
        try? await reloadFavorites()
        try await load(url: initialURL ?? session.baseURL, clearRows: true, policy: .preferCache)
    }

    func disconnect(profileID: UUID) {
        guard session?.profileID == profileID else { return }
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
        let destination = itemURL(for: row)
        endSearchMode(restoreRows: false)
        backStack.append(currentURL)
        forwardStack.removeAll()
        do {
            try await load(url: destination, clearRows: true, policy: .preferCache)
        } catch {
            _ = backStack.popLast()
            throw error
        }
    }

    func navigate(to url: URL) async throws {
        guard let currentURL, url != currentURL else { return }
        backStack.append(currentURL)
        forwardStack.removeAll()
        endSearchMode(restoreRows: false)
        try await load(url: url, clearRows: true, policy: .preferCache)
    }

    func goBack() async throws {
        guard let destination = backStack.popLast(), let currentURL else { return }
        forwardStack.append(currentURL)
        try await load(url: destination, clearRows: true, policy: .preferCache)
    }

    func goForward() async throws {
        guard let destination = forwardStack.popLast(), let currentURL else { return }
        backStack.append(currentURL)
        try await load(url: destination, clearRows: true, policy: .preferCache)
    }

    func refresh() async throws {
        guard let session, let currentURL else { return }
        endSearchMode(restoreRows: false)
        try await load(url: currentURL, clearRows: false, policy: .reload)
        noticeText = "目录缓存已刷新"
        onRepositoryChanged?(session.profileID, currentURL)
        onChange?()
    }

    var canGoBack: Bool { !backStack.isEmpty && !isBusy }
    var canGoForward: Bool { !forwardStack.isEmpty && !isBusy }

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
            cancellable: true
        ) {
            try await self.svnClient.export(
                url: request.sourceURL,
                to: destinationURL,
                revision: request.revision,
                overwrite: overwrite,
                options: request.options
            )
        }
        noticeText = "下载完成 · \(destinationURL.path)"
        onChange?()
    }

    func localURLForOpening(_ row: BrowserRow) async throws -> URL {
        guard let session else { throw SVNClientError.unsupportedOperation }
        let effectiveRevision: Int?
        if isShowingSearchResults {
            let liveInfo = try await svnClient.info(url: row.url, options: session.options)
            effectiveRevision = liveInfo.lastChangedRevision
        } else {
            effectiveRevision = row.revision
        }
        let cacheURL = try Self.openCacheURL(
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
        return cacheURL
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
        try await performTransfer(
            kind: .download,
            title: "下载 \(history.displayName) 的 r\(revision)",
            detail: "历史版本 · 保存为 \(destinationURL.lastPathComponent)",
            cancellable: true
        ) {
            try await self.svnClient.exportHistoricalVersion(
                url: history.sourceURL,
                pegRevision: history.pegRevision,
                revision: revision,
                to: destinationURL,
                overwrite: overwrite,
                options: history.options
            )
        }
        noticeText = "历史版本 r\(revision) 下载完成 · \(destinationURL.path)"
        onChange?()
    }

    func localURLForOpening(history: BrowserFileHistory, revision: Int) async throws -> URL {
        let cacheURL = try Self.openCacheURL(
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
        return cacheURL
    }

    func restore(
        history: BrowserFileHistory,
        revision: Int,
        message: String
    ) async throws -> SVNWriteResult {
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
            cancellable: false
        ) {
            try await self.svnClient.exportHistoricalVersion(
                url: history.sourceURL,
                pegRevision: history.pegRevision,
                revision: revision,
                to: historicalFileURL,
                overwrite: false,
                options: history.options
            )
            return try await self.svnClient.replace(
                localFileURL: historicalFileURL,
                targetURL: history.sourceURL,
                expectedRevision: history.currentRevision,
                message: message,
                options: history.options
            )
        }
        await invalidateDirectoryCache(profileID: history.profileID)
        if currentURL == history.sourceURL.deletingLastPathComponent() {
            try await refresh()
        }
        showWriteSuccess("已恢复 r\(revision) 的内容", result: result)
        return result
    }

    func toggleFavorite(_ row: BrowserRow) async throws -> Bool {
        guard let session, let metadataService else { throw SVNClientError.unsupportedOperation }
        let isFavorite = try await metadataService.toggleFavorite(
            profileID: session.profileID,
            url: row.url,
            name: row.name,
            kind: row.kind == .directory ? .directory : .file,
            revision: row.revision
        )
        if isFavorite {
            favoriteURLKeys.insert(row.url.absoluteString)
        } else {
            favoriteURLKeys.remove(row.url.absoluteString)
        }
        noticeText = isFavorite ? "已添加到收藏" : "已从收藏移除"
        onMetadataChanged?()
        onChange?()
        return isFavorite
    }

    func isFavorite(_ row: BrowserRow) -> Bool {
        favoriteURLKeys.contains(row.url.absoluteString)
    }

    func reloadFavorites() async throws {
        guard let session, let metadataService else {
            favoriteURLKeys = []
            return
        }
        favoriteURLKeys = Set(
            try await metadataService.favorites()
                .filter { $0.profileID == session.profileID }
                .map { $0.url.absoluteString }
        )
    }

    func refreshSearchIndex() async throws {
        guard let session, let metadataService else { throw SVNClientError.unsupportedOperation }
        let rootURL = session.searchRootURL
        let entries = try await performActivity("正在更新文件名索引…", cancellable: true) {
            try await self.svnClient.listRecursively(url: rootURL, options: session.options)
        }
        try Task.checkCancellation()
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
        searchIndexedAt = indexedAt
        noticeText = "索引更新完成 · \(indexedEntries.count) 项"
        if !searchQuery.isEmpty {
            try await search(query: searchQuery, scope: searchScope, refreshIfMissing: false)
        }
        onChange?()
    }

    func search(query: String, scope: SearchScope, refreshIfMissing: Bool = true) async throws {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            clearSearch()
            return
        }
        guard let session, let metadataService else { throw SVNClientError.unsupportedOperation }
        searchQuery = normalizedQuery
        searchScope = scope
        var results = try await metadataService.search(
            profileID: session.profileID,
            rootURL: session.searchRootURL,
            directoryURL: scope == .currentDirectory ? currentURL : nil,
            query: normalizedQuery
        )
        if results.indexedAt == nil, refreshIfMissing {
            try await refreshSearchIndex()
            results = try await metadataService.search(
                profileID: session.profileID,
                rootURL: session.searchRootURL,
                directoryURL: scope == .currentDirectory ? currentURL : nil,
                query: normalizedQuery
            )
        }
        rows = results.entries.map(BrowserRow.init(searchEntry:))
        isShowingSearchResults = true
        searchIndexedAt = results.indexedAt
        noticeText = nil
        onChange?()
    }

    func clearSearch() {
        endSearchMode(restoreRows: true)
        onChange?()
    }

    func createDirectory(name: String, message: String) async throws -> SVNWriteResult {
        guard let session, let currentURL else { throw SVNClientError.unsupportedOperation }
        let result = try await performActivity("正在新建文件夹…") {
            try await self.svnClient.makeDirectory(
                url: currentURL.appendingPathComponent(name, isDirectory: true),
                message: message,
                options: session.options
            )
        }
        await invalidateDirectoryCache(profileID: session.profileID)
        try await refresh()
        showWriteSuccess("文件夹已创建", result: result)
        return result
    }

    func rename(_ row: BrowserRow, to name: String, message: String) async throws -> SVNWriteResult {
        guard let session, let currentURL else { throw SVNClientError.unsupportedOperation }
        let sourceURL = itemURL(for: row)
        let destinationURL = currentURL.appendingPathComponent(name, isDirectory: row.kind == .directory)
        let result = try await performActivity("正在重命名“\(row.name)”…") {
            try await self.svnClient.move(
                from: sourceURL,
                to: destinationURL,
                message: message,
                options: session.options
            )
        }
        await invalidateDirectoryCache(profileID: session.profileID)
        try await refresh()
        try? await metadataService?.movePaths(profileID: session.profileID, from: sourceURL, to: destinationURL)
        try? await reloadFavorites()
        showWriteSuccess("重命名完成", result: result)
        onMetadataChanged?()
        return result
    }

    func delete(_ row: BrowserRow, message: String) async throws -> SVNWriteResult {
        guard let session else { throw SVNClientError.unsupportedOperation }
        let deletedURL = itemURL(for: row)
        let result = try await performActivity("正在删除“\(row.name)”…") {
            try await self.svnClient.delete(
                url: self.itemURL(for: row),
                message: message,
                options: session.options
            )
        }
        await invalidateDirectoryCache(profileID: session.profileID)
        try await refresh()
        try? await metadataService?.markFavoritesUnavailable(profileID: session.profileID, atOrBelow: deletedURL)
        showWriteSuccess("删除完成", result: result)
        onMetadataChanged?()
        return result
    }

    func upload(files: [URL], message: String) async throws -> SVNWriteResult {
        guard let session, let currentURL else { throw SVNClientError.unsupportedOperation }
        let existingNames = Set(rows.map(\.name))
        if let conflict = files.first(where: { existingNames.contains($0.lastPathComponent) }) {
            throw SVNClientError.commandFailed(SVNCommandFailure(
                operation: "upload",
                exitStatus: 1,
                standardOutput: "",
                standardError: "already exists: \(conflict.lastPathComponent)"
            ))
        }
        let totalBytes = files.reduce(Int64(0)) { partial, url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            return partial + Int64(values?.fileSize ?? 0)
        }
        let result = try await performTransfer(
            kind: .upload,
            title: "上传 \(files.count) 个文件",
            detail: ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file),
            cancellable: false
        ) {
            try await self.svnClient.upload(
                files: files,
                to: currentURL,
                message: message,
                options: session.options
            )
        }
        await invalidateDirectoryCache(profileID: session.profileID)
        try await refresh()
        showWriteSuccess("上传完成", result: result)
        return result
    }

    func replace(_ row: BrowserRow, with localFileURL: URL, message: String) async throws -> SVNWriteResult {
        guard let session, let revision = row.revision else { throw SVNClientError.remoteChanged }
        let localSize = (try? localFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "大小未知"
        let result = try await performTransfer(
            kind: .replace,
            title: "替换 \(row.name)",
            detail: localSize,
            cancellable: false
        ) {
            try await self.svnClient.replace(
                localFileURL: localFileURL,
                targetURL: self.itemURL(for: row),
                expectedRevision: revision,
                message: message,
                options: session.options
            )
        }
        await invalidateDirectoryCache(profileID: session.profileID)
        try await refresh()
        showWriteSuccess("替换完成", result: result)
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

    private func load(url: URL, clearRows: Bool, policy: DirectoryLoadPolicy) async throws {
        guard let session else { return }
        if policy == .preferCache,
           let snapshot = try? await metadataService?.directoryCache(profileID: session.profileID, url: url) {
            applyDirectoryEntries(snapshot.entries, url: url, cachedAt: snapshot.cachedAt)
            return
        }
        let previousRows = rows
        let previousURL = currentURL
        let previousState = state
        state = .loading
        isBusy = true
        isCancellable = true
        activityText = "正在读取目录…"
        noticeText = nil
        if clearRows { rows = [] }
        onChange?()

        do {
            let entries = try await svnClient.list(url: url, options: session.options)
            let cachedAt = Date()
            try? await metadataService?.replaceDirectoryCache(
                profileID: session.profileID,
                url: url,
                entries: entries,
                cachedAt: cachedAt
            )
            applyDirectoryEntries(entries, url: url, cachedAt: cachedAt)
        } catch is CancellationError {
            rows = previousRows
            currentURL = previousURL
            state = previousState
            isBusy = false
            isCancellable = false
            activityText = nil
            onChange?()
            throw CancellationError()
        } catch {
            state = .failed(error.localizedDescription)
            isBusy = false
            isCancellable = false
            activityText = nil
            onChange?()
            throw error
        }
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

    private func invalidateDirectoryCache(profileID: UUID) async {
        try? await metadataService?.clearDirectoryCache(profileID: profileID)
    }

    private func performActivity<Result: Sendable>(
        _ text: String,
        cancellable: Bool = false,
        operation: () async throws -> Result
    ) async throws -> Result {
        isBusy = true
        isCancellable = cancellable
        activityText = text
        noticeText = nil
        onChange?()
        do {
            let result = try await operation()
            isBusy = false
            isCancellable = false
            activityText = nil
            onChange?()
            return result
        } catch {
            isBusy = false
            isCancellable = false
            activityText = nil
            onChange?()
            throw error
        }
    }

    private func performTransfer<Result: Sendable>(
        kind: BrowserTransfer.Kind,
        title: String,
        detail: String,
        cancellable: Bool,
        operation: () async throws -> Result
    ) async throws -> Result {
        let id = UUID()
        transfers.insert(
            BrowserTransfer(
                id: id,
                kind: kind,
                title: title,
                detail: detail,
                state: .running,
                startedAt: .now,
                finishedAt: nil
            ),
            at: 0
        )
        trimTransferHistory()
        onChange?()
        do {
            let result = try await performActivity(
                "正在\(title)…",
                cancellable: cancellable,
                operation: operation
            )
            finishTransfer(id: id, state: .completed)
            return result
        } catch is CancellationError {
            finishTransfer(id: id, state: .cancelled)
            throw CancellationError()
        } catch {
            finishTransfer(id: id, state: .failed(error.localizedDescription))
            throw error
        }
    }

    func clearFinishedTransfers() {
        transfers.removeAll { $0.state != .running }
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
        if restoreRows { rows = browsingRows }
        isShowingSearchResults = false
        searchQuery = ""
        searchIndexedAt = nil
    }

    private static func openCacheURL(profileID: UUID, revision: Int?, itemURL: URL) throws -> URL {
        let cacheRoot = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("SVNClient/OpenCache", isDirectory: true)
        let revision = revision.map(String.init) ?? "HEAD"
        let pathComponents = itemURL.pathComponents.filter { $0 != "/" }
        return pathComponents.reduce(
            cacheRoot.appendingPathComponent(profileID.uuidString).appendingPathComponent(revision),
            { $0.appendingPathComponent($1) }
        )
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
