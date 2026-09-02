import Foundation
import XCTest
@testable import SVNClient

@MainActor
final class BrowserViewModelTests: XCTestCase {
    func testConnectLoadsAndFormatsRepositoryEntries() async throws {
        let client = MockSVNClient(result: .success([
            SVNListEntry(
                name: "技术资料",
                kind: .directory,
                size: nil,
                revision: 12,
                author: "zhangsan",
                updatedAt: Date(timeIntervalSince1970: 0)
            ),
            SVNListEntry(
                name: "接口说明.pdf",
                kind: .file,
                size: 2_621_440,
                revision: 13,
                author: "lisi",
                updatedAt: nil
            )
        ]))
        let viewModel = BrowserViewModel(svnClient: client)
        let url = try XCTUnwrap(URL(string: "https://svn.example.com/company"))

        try await viewModel.connect(to: url)

        XCTAssertEqual(viewModel.state, .loaded(url))
        XCTAssertEqual(viewModel.rows.map(\.name), ["技术资料", "接口说明.pdf"])
        XCTAssertEqual(viewModel.rows[0].kind, .directory)
        XCTAssertEqual(viewModel.rows[1].author, "lisi")
        XCTAssertNotEqual(viewModel.rows[1].size, "—")
    }

    func testConnectFailureIsRenderedAndRethrown() async {
        let expectedError = SVNClientError.invalidListXML
        let viewModel = BrowserViewModel(svnClient: MockSVNClient(result: .failure(expectedError)))
        let url = URL(fileURLWithPath: "/tmp/missing-repository")

        do {
            try await viewModel.connect(to: url)
            XCTFail("Expected connection to fail")
        } catch {
            XCTAssertEqual(error as? SVNClientError, expectedError)
        }

        guard case .failed = viewModel.state else {
            return XCTFail("Expected failed view state")
        }
        XCTAssertTrue(viewModel.rows.isEmpty)
    }

    func testConfiguredStartPathAndDirectoryNavigationBuildReadableBreadcrumbs() async throws {
        let rootURL = try XCTUnwrap(URL(string: "https://svn.example.com/company"))
        let client = RoutingSVNClient(entriesByURL: [
            "https://svn.example.com/company/%E6%8A%80%E6%9C%AF%E9%83%A8": [
                SVNListEntry(name: "共享资料", kind: .directory, size: nil, revision: 8, author: nil, updatedAt: nil)
            ],
            "https://svn.example.com/company/%E6%8A%80%E6%9C%AF%E9%83%A8/%E5%85%B1%E4%BA%AB%E8%B5%84%E6%96%99/": []
        ])
        let viewModel = BrowserViewModel(svnClient: client)
        let profile = RepositoryProfile(
            id: UUID(),
            displayName: "公司文档",
            baseURL: rootURL,
            username: "",
            certificatePolicy: .strict,
            startPath: "技术部",
            createdAt: .now,
            updatedAt: .now
        )

        try await viewModel.connect(profile: profile, password: nil)

        XCTAssertEqual(viewModel.currentURL, profile.startURL)
        XCTAssertEqual(viewModel.breadcrumbs.map(\.title), ["公司文档", "技术部"])
        try await viewModel.openDirectory(try XCTUnwrap(viewModel.rows.first))
        XCTAssertEqual(viewModel.breadcrumbs.map(\.title), ["公司文档", "技术部", "共享资料"])
        XCTAssertTrue(viewModel.canGoBack)
        try await viewModel.goBack()
        XCTAssertEqual(viewModel.currentURL, profile.startURL)
        XCTAssertTrue(viewModel.canGoForward)
    }

    func testDisplayPathIsReadableWhileRepositoryURLRemainsEncoded() async throws {
        let rootURL = try XCTUnwrap(URL(string: "https://svn.example.com/repo"))
        let client = MockSVNClient(result: .success([
            SVNListEntry(name: "接口说明.pdf", kind: .file, size: 10, revision: 2, author: nil, updatedAt: nil)
        ]))
        let viewModel = BrowserViewModel(svnClient: client)
        let profile = RepositoryProfile(
            id: UUID(),
            displayName: "公司文档",
            baseURL: rootURL,
            username: "",
            certificatePolicy: .strict,
            createdAt: .now,
            updatedAt: .now
        )

        try await viewModel.connect(profile: profile, password: nil)
        let row = try XCTUnwrap(viewModel.rows.first)

        XCTAssertEqual(viewModel.displayPath(for: row), "公司文档 / 接口说明.pdf")
        XCTAssertTrue(viewModel.itemURL(for: row).absoluteString.contains("%E6%8E%A5%E5%8F%A3%E8%AF%B4%E6%98%8E.pdf"))
    }

    func testWriteSuccessShowsCommittedRevisionAfterRefresh() async throws {
        let viewModel = BrowserViewModel(svnClient: WriteSVNClient(revision: 42))
        let url = try XCTUnwrap(URL(string: "https://svn.example.com/company"))

        try await viewModel.connect(to: url)
        let result = try await viewModel.createDirectory(name: "新目录", message: "创建新目录")

        XCTAssertEqual(result.revision, 42)
        XCTAssertEqual(viewModel.noticeText, "文件夹已创建 · r42")
        XCTAssertEqual(viewModel.statusText, "文件夹已创建 · r42")
    }

    func testPromisedDownloadKeepsOriginalURLRevisionAndCredentialsAfterNavigationChanges() async throws {
        let client = DownloadSVNClient()
        let viewModel = BrowserViewModel(svnClient: client)
        let originalURL = try XCTUnwrap(URL(string: "https://svn.example.com/original"))
        let profile = RepositoryProfile(
            id: UUID(),
            displayName: "原仓库",
            baseURL: originalURL,
            username: "original-user",
            certificatePolicy: .allowUnknownCertificateAuthority,
            createdAt: .now,
            updatedAt: .now
        )
        try await viewModel.connect(profile: profile, password: "original-password")
        let row = try XCTUnwrap(viewModel.rows.first)
        let request = try XCTUnwrap(viewModel.downloadRequest(for: row))

        try await viewModel.connect(to: try XCTUnwrap(URL(string: "https://svn.example.com/other")))
        try await viewModel.download(
            request,
            to: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            overwrite: false
        )

        let recordedExport = await client.lastExport
        let export = try XCTUnwrap(recordedExport)
        XCTAssertEqual(export.url, originalURL.appendingPathComponent("说明.txt"))
        XCTAssertEqual(export.revision, 17)
        XCTAssertEqual(export.options.credentials?.username, "original-user")
        XCTAssertEqual(export.options.credentials?.password, "original-password")
        XCTAssertEqual(export.options.certificateTrustPolicy, .allowUnknownCertificateAuthority)
    }

    func testSearchBuildsLocalIndexOnDemandAndFiltersCurrentDirectory() async throws {
        let store = try RepositoryMetadataStore(inMemory: ())
        let metadata = RepositoryMetadataService(store: store)
        let client = SearchSVNClient()
        let viewModel = BrowserViewModel(svnClient: client, metadataService: metadata)
        let rootURL = try XCTUnwrap(URL(string: "https://svn.example.com/repo/"))
        let profile = RepositoryProfile(
            id: UUID(), displayName: "公司文档", baseURL: rootURL, username: "",
            certificatePolicy: .strict, createdAt: .now, updatedAt: .now
        )

        try await viewModel.connect(profile: profile, password: nil)
        let technicalDirectory = try XCTUnwrap(viewModel.rows.first(where: { $0.name == "技术部" }))
        try await viewModel.openDirectory(technicalDirectory)
        try await viewModel.search(query: "api", scope: .currentDirectory)

        XCTAssertTrue(viewModel.isShowingSearchResults)
        XCTAssertEqual(viewModel.rows.map(\.name), ["API-Guide.txt"])
        XCTAssertEqual(viewModel.rows.first?.location, "技术部")
        XCTAssertNotNil(viewModel.searchIndexedAt)
        XCTAssertTrue(viewModel.statusText.contains("索引更新于"))
        let firstRecursiveListCount = await client.recursiveListCount
        XCTAssertEqual(firstRecursiveListCount, 1)
        _ = try await viewModel.localURLForOpening(try XCTUnwrap(viewModel.rows.first))
        let liveInfoCount = await client.infoCount
        let liveExportRevision = await client.lastExportRevision
        XCTAssertEqual(liveInfoCount, 1, "Opening an indexed result must validate it against the server")
        XCTAssertEqual(liveExportRevision, 5, "The validated live revision must replace the stale indexed revision")

        try await viewModel.search(query: "api", scope: .configuredRoot)
        XCTAssertEqual(Set(viewModel.rows.map(\.name)), ["API-Guide.txt", "api-plan.txt"])
        let secondRecursiveListCount = await client.recursiveListCount
        XCTAssertEqual(secondRecursiveListCount, 1, "Subsequent searches must use the local index")
    }

    func testFavoritesArePersistedAndReflectedSynchronouslyInTheContextMenuState() async throws {
        let store = try RepositoryMetadataStore(inMemory: ())
        let metadata = RepositoryMetadataService(store: store)
        let client = SearchSVNClient()
        let viewModel = BrowserViewModel(svnClient: client, metadataService: metadata)
        let rootURL = try XCTUnwrap(URL(string: "https://svn.example.com/repo/"))
        let profile = RepositoryProfile(
            id: UUID(), displayName: "公司文档", baseURL: rootURL, username: "",
            certificatePolicy: .strict, createdAt: .now, updatedAt: .now
        )

        try await viewModel.connect(profile: profile, password: nil)
        let file = try XCTUnwrap(viewModel.rows.first(where: { $0.name == "README.txt" }))
        XCTAssertFalse(viewModel.isFavorite(file))
        let wasAdded = try await viewModel.toggleFavorite(file)
        XCTAssertTrue(wasAdded)
        XCTAssertTrue(viewModel.isFavorite(file))

        let favorites = try await metadata.favorites()
        XCTAssertEqual(favorites.map(\.url), [file.url])

        let wasRemoved = try await viewModel.toggleFavorite(file)
        XCTAssertFalse(wasRemoved)
        XCTAssertFalse(viewModel.isFavorite(file))
    }

    func testDirectoryNavigationUsesCacheAndRefreshForcesOneServerReload() async throws {
        let store = try RepositoryMetadataStore(inMemory: ())
        let metadata = RepositoryMetadataService(store: store)
        let client = CachingSVNClient()
        let viewModel = BrowserViewModel(svnClient: client, metadataService: metadata)
        let rootURL = try XCTUnwrap(URL(string: "https://svn.example.com/repo/"))
        let profile = RepositoryProfile(
            id: UUID(), displayName: "公司文档", baseURL: rootURL, username: "",
            certificatePolicy: .strict, createdAt: .now, updatedAt: .now
        )

        try await viewModel.connect(profile: profile, password: nil)
        let directory = try XCTUnwrap(viewModel.rows.first(where: { $0.kind == .directory }))
        try await viewModel.openDirectory(directory)
        try await viewModel.goBack()

        let countsBeforeRefresh = await client.callCounts
        XCTAssertEqual(countsBeforeRefresh[rootURL.absoluteString], 1)
        XCTAssertEqual(countsBeforeRefresh[directory.url.absoluteString], 1)

        try await viewModel.refresh()
        let countsAfterRefresh = await client.callCounts
        XCTAssertEqual(countsAfterRefresh[rootURL.absoluteString], 2)
        XCTAssertTrue(viewModel.rows.contains(where: { $0.name == "刷新后.txt" }))
        XCTAssertEqual(viewModel.noticeText, "目录缓存已刷新")
    }

    func testDownloadCreatesCompletedTransferRecordThatCanBeCleared() async throws {
        let client = DownloadSVNClient()
        let viewModel = BrowserViewModel(svnClient: client)
        let rootURL = try XCTUnwrap(URL(string: "https://svn.example.com/repo/"))
        try await viewModel.connect(to: rootURL)
        let row = try XCTUnwrap(viewModel.rows.first)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("transfer-\(UUID().uuidString).txt")

        try await viewModel.download(row, to: destination, overwrite: false)

        let transfer = try XCTUnwrap(viewModel.transfers.first)
        XCTAssertEqual(transfer.title, "下载 说明.txt")
        XCTAssertEqual(transfer.state, .completed)
        XCTAssertEqual(viewModel.activeTransferCount, 0)
        viewModel.clearFinishedTransfers()
        XCTAssertTrue(viewModel.transfers.isEmpty)
    }

    func testCancellingDownloadMarksTransferAsCancelled() async throws {
        let client = CancellableTransferSVNClient()
        let viewModel = BrowserViewModel(svnClient: client)
        let rootURL = try XCTUnwrap(URL(string: "https://svn.example.com/repo/"))
        try await viewModel.connect(to: rootURL)
        let row = try XCTUnwrap(viewModel.rows.first)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("cancelled-transfer-\(UUID().uuidString).txt")
        let task = Task { @MainActor in
            try await viewModel.download(row, to: destination, overwrite: false)
        }
        while viewModel.activeTransferCount == 0 { await Task.yield() }

        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertEqual(viewModel.transfers.first?.state, .cancelled)
        XCTAssertEqual(viewModel.activeTransferCount, 0)
    }

    func testHistoricalDownloadAndRestoreUsePegAndCurrentRevisionSnapshot() async throws {
        let client = HistorySVNClient()
        let viewModel = BrowserViewModel(svnClient: client)
        let rootURL = try XCTUnwrap(URL(string: "https://svn.example.com/repo/"))
        try await viewModel.connect(to: rootURL)
        let row = try XCTUnwrap(viewModel.rows.first)

        let history = try await viewModel.history(for: row)

        XCTAssertEqual(history.currentRevision, 9)
        XCTAssertEqual(history.pegRevision, 12)
        XCTAssertEqual(history.entries.map(\.revision), [9, 4])

        let downloadURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: downloadURL) }
        try await viewModel.download(history: history, revision: 4, to: downloadURL, overwrite: false)
        XCTAssertEqual(try String(contentsOf: downloadURL, encoding: .utf8), "第四版内容")

        let result = try await viewModel.restore(
            history: history,
            revision: 4,
            message: "恢复旧版"
        )

        XCTAssertEqual(result.revision, 13)
        let exports = await client.historicalExports
        let replacedExpectedRevision = await client.replacedExpectedRevision
        let replacedContents = await client.replacedContents
        XCTAssertEqual(exports.count, 2)
        XCTAssertTrue(exports.allSatisfy { $0.pegRevision == 12 && $0.revision == 4 })
        XCTAssertEqual(replacedExpectedRevision, 9)
        XCTAssertEqual(replacedContents, "第四版内容")
        XCTAssertEqual(viewModel.noticeText, "已恢复 r4 的内容 · r13")
    }
}

private final class MockSVNClient: SVNClient, Sendable {
    private let result: Result<[SVNListEntry], SVNClientError>

    init(result: Result<[SVNListEntry], SVNClientError>) {
        self.result = result
    }

    func version() async throws -> String {
        "1.14.5"
    }

    func list(url: URL, options: SVNRequestOptions) async throws -> [SVNListEntry] {
        try result.get()
    }
}

private final class RoutingSVNClient: SVNClient, Sendable {
    private let entriesByURL: [String: [SVNListEntry]]

    init(entriesByURL: [String: [SVNListEntry]]) {
        self.entriesByURL = entriesByURL
    }

    func version() async throws -> String { "1.14.5" }

    func list(url: URL, options: SVNRequestOptions) async throws -> [SVNListEntry] {
        if let entries = entriesByURL[url.absoluteString] { return entries }
        if let entries = entriesByURL[url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))] {
            return entries
        }
        return []
    }
}

private final class WriteSVNClient: SVNClient, Sendable {
    private let revision: Int

    init(revision: Int) {
        self.revision = revision
    }

    func version() async throws -> String { "1.14.5" }

    func list(url: URL, options: SVNRequestOptions) async throws -> [SVNListEntry] { [] }

    func makeDirectory(url: URL, message: String, options: SVNRequestOptions) async throws -> SVNWriteResult {
        SVNWriteResult(revision: revision)
    }
}

private actor DownloadSVNClient: SVNClient {
    struct Export: Sendable {
        let url: URL
        let revision: Int?
        let options: SVNRequestOptions
    }

    private(set) var lastExport: Export?

    func version() async throws -> String { "1.14.5" }

    func list(url: URL, options: SVNRequestOptions) async throws -> [SVNListEntry] {
        [SVNListEntry(name: "说明.txt", kind: .file, size: 10, revision: 17, author: nil, updatedAt: nil)]
    }

    func export(
        url: URL,
        to destinationURL: URL,
        revision: Int?,
        overwrite: Bool,
        options: SVNRequestOptions
    ) async throws {
        lastExport = Export(url: url, revision: revision, options: options)
    }
}

private actor SearchSVNClient: SVNClient {
    private(set) var recursiveListCount = 0
    private(set) var infoCount = 0
    private(set) var lastExportRevision: Int?

    func version() async throws -> String { "1.14.5" }

    func list(url: URL, options: SVNRequestOptions) async throws -> [SVNListEntry] {
        if url.path.hasSuffix("技术部") || url.path.hasSuffix("技术部/") {
            return [SVNListEntry(
                name: "API-Guide.txt", kind: .file, size: 20, revision: 8,
                author: "tester", updatedAt: Date(timeIntervalSince1970: 300)
            )]
        }
        return [
            SVNListEntry(name: "技术部", kind: .directory, size: nil, revision: 7, author: "tester", updatedAt: nil),
            SVNListEntry(name: "README.txt", kind: .file, size: 10, revision: 5, author: "tester", updatedAt: nil)
        ]
    }

    func listRecursively(url: URL, options: SVNRequestOptions) async throws -> [SVNListEntry] {
        recursiveListCount += 1
        return [
            SVNListEntry(name: "技术部", kind: .directory, size: nil, revision: 7, author: "tester", updatedAt: nil),
            SVNListEntry(name: "技术部/API-Guide.txt", kind: .file, size: 20, revision: 8, author: "tester", updatedAt: nil),
            SVNListEntry(name: "市场部/api-plan.txt", kind: .file, size: 30, revision: 9, author: "tester", updatedAt: nil)
        ]
    }

    func info(url: URL, options: SVNRequestOptions) async throws -> SVNItemInfo {
        infoCount += 1
        return SVNItemInfo(
            name: url.lastPathComponent,
            url: url,
            kind: .file,
            size: 10,
            revision: 5,
            lastChangedRevision: 5,
            author: "tester",
            updatedAt: nil,
            properties: [:]
        )
    }

    func export(
        url: URL,
        to destinationURL: URL,
        revision: Int?,
        overwrite: Bool,
        options: SVNRequestOptions
    ) async throws {
        lastExportRevision = revision
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("test".utf8).write(to: destinationURL)
    }
}

private actor CachingSVNClient: SVNClient {
    private(set) var callCounts: [String: Int] = [:]

    func version() async throws -> String { "1.14.5" }

    func list(url: URL, options: SVNRequestOptions) async throws -> [SVNListEntry] {
        callCounts[url.absoluteString, default: 0] += 1
        if url.lastPathComponent == "资料" {
            return [SVNListEntry(name: "文档.txt", kind: .file, size: 1, revision: 1, author: nil, updatedAt: nil)]
        }
        let rootCallCount = callCounts[url.absoluteString, default: 0]
        return [
            SVNListEntry(name: "资料", kind: .directory, size: nil, revision: 1, author: nil, updatedAt: nil),
            SVNListEntry(
                name: rootCallCount > 1 ? "刷新后.txt" : "初始.txt",
                kind: .file,
                size: 1,
                revision: rootCallCount,
                author: nil,
                updatedAt: nil
            )
        ]
    }
}

private actor CancellableTransferSVNClient: SVNClient {
    func version() async throws -> String { "1.14.5" }

    func list(url: URL, options: SVNRequestOptions) async throws -> [SVNListEntry] {
        [SVNListEntry(name: "大文件.zip", kind: .file, size: 1024, revision: 2, author: nil, updatedAt: nil)]
    }

    func export(
        url: URL,
        to destinationURL: URL,
        revision: Int?,
        overwrite: Bool,
        options: SVNRequestOptions
    ) async throws {
        try await Task.sleep(for: .seconds(60))
    }
}

private actor HistorySVNClient: SVNClient {
    struct HistoricalExport: Sendable {
        let pegRevision: Int
        let revision: Int
    }

    private(set) var historicalExports: [HistoricalExport] = []
    private(set) var replacedExpectedRevision: Int?
    private(set) var replacedContents: String?

    func version() async throws -> String { "1.14.5" }

    func list(url: URL, options: SVNRequestOptions) async throws -> [SVNListEntry] {
        [SVNListEntry(name: "说明.txt", kind: .file, size: 12, revision: 9, author: "lisi", updatedAt: nil)]
    }

    func info(url: URL, options: SVNRequestOptions) async throws -> SVNItemInfo {
        SVNItemInfo(
            name: "说明.txt",
            url: url,
            kind: .file,
            size: 12,
            revision: 12,
            lastChangedRevision: 9,
            author: "lisi",
            updatedAt: nil,
            properties: [:]
        )
    }

    func log(
        url: URL,
        pegRevision: Int?,
        limit: Int,
        options: SVNRequestOptions
    ) async throws -> [SVNLogEntry] {
        [
            SVNLogEntry(revision: 4, author: "zhangsan", date: nil, message: "第四版"),
            SVNLogEntry(revision: 9, author: "lisi", date: nil, message: "第九版")
        ]
    }

    func exportHistoricalVersion(
        url: URL,
        pegRevision: Int,
        revision: Int,
        to destinationURL: URL,
        overwrite: Bool,
        options: SVNRequestOptions
    ) async throws {
        historicalExports.append(HistoricalExport(pegRevision: pegRevision, revision: revision))
        try Data("第四版内容".utf8).write(to: destinationURL)
    }

    func replace(
        localFileURL: URL,
        targetURL: URL,
        expectedRevision: Int,
        message: String,
        options: SVNRequestOptions
    ) async throws -> SVNWriteResult {
        replacedExpectedRevision = expectedRevision
        replacedContents = try String(contentsOf: localFileURL, encoding: .utf8)
        return SVNWriteResult(revision: 13)
    }
}
