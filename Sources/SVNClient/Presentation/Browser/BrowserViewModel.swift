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
    let revision: Int?
    let options: SVNRequestOptions
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
    var onRepositoryChanged: ((UUID) -> Void)?
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
    private(set) var session: RepositorySession?
    private(set) var currentURL: URL?
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    private var browsingRows: [BrowserRow] = []
    private let svnClient: any SVNClient
    private let metadataService: RepositoryMetadataService?

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
        try await load(url: initialURL ?? session.baseURL, clearRows: true)
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
            try await load(url: destination, clearRows: true)
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
        try await load(url: url, clearRows: true)
    }

    func goBack() async throws {
        guard let destination = backStack.popLast(), let currentURL else { return }
        forwardStack.append(currentURL)
        try await load(url: destination, clearRows: true)
    }

    func goForward() async throws {
        guard let destination = forwardStack.popLast(), let currentURL else { return }
        backStack.append(currentURL)
        try await load(url: destination, clearRows: true)
    }

    func refresh() async throws {
        guard let currentURL else { return }
        endSearchMode(restoreRows: false)
        try await load(url: currentURL, clearRows: false)
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
            revision: row.kind == .file ? row.revision : nil,
            options: session.options
        )
    }

    func download(_ request: BrowserDownloadRequest, to destinationURL: URL, overwrite: Bool) async throws {
        try await performActivity("正在下载到 \(destinationURL.path)…", cancellable: true) {
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
            session: session,
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
                    revision: effectiveRevision,
                    options: session.options
                ),
                to: cacheURL,
                overwrite: true
            )
        }
        try? await recordRecent(row: row, revision: effectiveRevision)
        return cacheURL
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
        noticeText = isFavorite ? "已添加到收藏" : "已从收藏移除"
        onMetadataChanged?()
        onChange?()
        return isFavorite
    }

    func isFavorite(_ row: BrowserRow) async throws -> Bool {
        guard let session, let metadataService else { return false }
        return try await metadataService.isFavorite(profileID: session.profileID, url: row.url)
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
        try await refresh()
        showWriteSuccess("文件夹已创建", result: result)
        onRepositoryChanged?(session.profileID)
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
        try await refresh()
        try? await metadataService?.movePaths(profileID: session.profileID, from: sourceURL, to: destinationURL)
        showWriteSuccess("重命名完成", result: result)
        onRepositoryChanged?(session.profileID)
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
        try await refresh()
        try? await metadataService?.markFavoritesUnavailable(profileID: session.profileID, atOrBelow: deletedURL)
        showWriteSuccess("删除完成", result: result)
        onRepositoryChanged?(session.profileID)
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
        let result = try await performActivity("正在上传 \(files.count) 个文件…") {
            try await self.svnClient.upload(
                files: files,
                to: currentURL,
                message: message,
                options: session.options
            )
        }
        try await refresh()
        showWriteSuccess("上传完成", result: result)
        onRepositoryChanged?(session.profileID)
        return result
    }

    func replace(_ row: BrowserRow, with localFileURL: URL, message: String) async throws -> SVNWriteResult {
        guard let session, let revision = row.revision else { throw SVNClientError.remoteChanged }
        let result = try await performActivity("正在替换“\(row.name)”…") {
            try await self.svnClient.replace(
                localFileURL: localFileURL,
                targetURL: self.itemURL(for: row),
                expectedRevision: revision,
                message: message,
                options: session.options
            )
        }
        try await refresh()
        showWriteSuccess("替换完成", result: result)
        onRepositoryChanged?(session.profileID)
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

    private func load(url: URL, clearRows: Bool) async throws {
        guard let session else { return }
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
            rows = entries.map { BrowserRow(entry: $0, parentURL: url) }
            browsingRows = rows
            isShowingSearchResults = false
            currentURL = url
            state = .loaded(url)
            isBusy = false
            isCancellable = false
            activityText = nil
            onChange?()
            try? await recordRecentDirectory(url: url)
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

    private func showWriteSuccess(_ message: String, result: SVNWriteResult) {
        noticeText = result.revision.map { "\(message) · r\($0)" } ?? message
        onChange?()
    }

    private func recordRecentDirectory(url: URL) async throws {
        guard let session, let metadataService else { return }
        let name = url == session.baseURL
            ? session.displayName
            : url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        try await metadataService.recordRecent(
            profileID: session.profileID,
            url: url,
            name: name,
            kind: .directory,
            revision: nil
        )
        onMetadataChanged?()
    }

    private func recordRecent(row: BrowserRow, revision: Int?) async throws {
        guard let session, let metadataService else { return }
        try await metadataService.recordRecent(
            profileID: session.profileID,
            url: row.url,
            name: row.name,
            kind: row.kind == .directory ? .directory : .file,
            revision: revision
        )
        onMetadataChanged?()
    }

    private func endSearchMode(restoreRows: Bool) {
        if restoreRows { rows = browsingRows }
        isShowingSearchResults = false
        searchQuery = ""
        searchIndexedAt = nil
    }

    private static func openCacheURL(session: RepositorySession, revision: Int?, itemURL: URL) throws -> URL {
        let cacheRoot = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("SVNClient/OpenCache", isDirectory: true)
        let revision = revision.map(String.init) ?? "HEAD"
        let pathComponents = itemURL.pathComponents.filter { $0 != "/" }
        return pathComponents.reduce(
            cacheRoot.appendingPathComponent(session.profileID.uuidString).appendingPathComponent(revision),
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
            return rows.isEmpty ? "这个文件夹是空的" : "已连接 · \(url.host ?? session?.displayName ?? url.lastPathComponent) · \(rows.count) 项"
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
