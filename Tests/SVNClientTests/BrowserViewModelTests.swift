import Foundation
import AppKit
import XCTest
@testable import SVNClient

@MainActor
final class BrowserViewModelTests: XCTestCase {
    func testManualRefreshUpdatesExpandedDescendantsAndKeepsSelection() async throws {
        try await assertVisibleTreeRefresh(collapseParent: false)
    }

    func testManualRefreshDoesNotLoadCollapsedBranchesOrRememberedDescendants() async throws {
        try await assertVisibleTreeRefresh(collapseParent: true)
    }

    private func assertVisibleTreeRefresh(collapseParent: Bool) async throws {
        let metadata = RepositoryMetadataService(store: try RepositoryMetadataStore(inMemory: ()))
        let client = ExpandedRefreshSVNClient()
        let model = BrowserViewModel(svnClient: client, metadataService: metadata)
        let root = URL(string: "https://example.com/root")!
        try await model.connect(to: root)
        let controller = BrowserViewController(viewModel: model)
        _ = controller.view
        let scroll = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? NSScrollView }.first)
        let outline = try XCTUnwrap(scroll.documentView as? NSOutlineView)
        func index(named name: String) -> Int? {
            (0..<outline.numberOfRows).first { index in
                guard let item = outline.item(atRow: index) else { return false }
                return (controller.outlineView(outline, viewFor: outline.tableColumns[0], item: item) as? NSTableCellView)?.textField?.stringValue == name
            }
        }
        let folder = try XCTUnwrap(outline.item(atRow: try XCTUnwrap(index(named: "expanded"))))
        outline.expandItem(folder)
        for _ in 0..<1000 { if index(named: "nested") != nil { break }; await Task.yield() }
        let nested = try XCTUnwrap(outline.item(atRow: try XCTUnwrap(index(named: "nested"))))
        outline.expandItem(nested)
        for _ in 0..<1000 { if index(named: "old-leaf.txt") != nil { break }; await Task.yield() }
        XCTAssertNotNil(index(named: "old-leaf.txt"))
        let keepIndex = try XCTUnwrap(index(named: "keep.txt"))
        outline.selectRowIndexes(IndexSet(integer: keepIndex), byExtendingSelection: false)
        if collapseParent { outline.collapseItem(folder) }
        await client.setUpdated()
        try await controller.refreshVisibleDirectories()
        let counts = await client.counts
        XCTAssertEqual(counts["root"], 2)
        XCTAssertEqual(counts["expanded"], collapseParent ? 1 : 2)
        XCTAssertEqual(counts["nested"], collapseParent ? 1 : 2)
        XCTAssertNil(counts["closed"], "Never request unopened folders")
        XCTAssertEqual(outline.isItemExpanded(folder), !collapseParent)
        XCTAssertEqual(model.currentURL, root)
        XCTAssertFalse(model.canGoBack)
        XCTAssertFalse(model.isBusy)
        if !collapseParent {
            XCTAssertTrue(outline.isItemExpanded(nested))
            XCTAssertNotNil(index(named: "new-leaf.txt"))
            XCTAssertNil(index(named: "old-leaf.txt"))
            XCTAssertEqual(outline.selectedRow, index(named: "keep.txt"))
            let childURL = root.appendingPathComponent("expanded", isDirectory: true).appendingPathComponent("nested", isDirectory: true)
            let cache = try await metadata.directoryCache(profileID: try XCTUnwrap(model.session?.profileID), url: childURL)
            XCTAssertEqual(cache?.entries.map(\.name), ["new-leaf.txt"])
        }
    }

    func testExpandedRefreshContinuesAfterOneFolderFailsAndKeepsItsCache() async throws {
        let client = ControlledListSVNClient()
        let metadata = RepositoryMetadataService(store: try RepositoryMetadataStore(inMemory: ()))
        let model = BrowserViewModel(svnClient: client, metadataService: metadata)
        let root = URL(string: "https://example.com/root")!
        let a = root.appendingPathComponent("a")
        let b = root.appendingPathComponent("b")
        try await model.connect(to: root)
        let profileID = try XCTUnwrap(model.session?.profileID)
        try await metadata.replaceDirectoryCache(profileID: profileID, url: a, entries: StabilitySVNClient.entries)
        try await metadata.replaceDirectoryCache(profileID: profileID, url: b, entries: StabilitySVNClient.entries)
        var refreshed: [URL] = []
        model.onTreeDirectoryRefreshed = { url, _ in refreshed.append(url) }
        let refresh = Task { try await model.refresh(expandedDirectoryURLs: [b, a, a]) }
        await client.waitForRequest(a)
        await client.waitForRequest(b)
        XCTAssertTrue(model.isBusy)
        let requestsBeforeEitherCompletes = await client.totalListCount
        XCTAssertEqual(requestsBeforeEitherCompletes, 4, "Connect, root refresh, and both expanded directories should all be observed before either child completes")
        await client.resolve(a, result: .failure(.connectionTimedOut))
        await client.resolve(b, result: .success([]))
        try await refresh.value
        XCTAssertEqual(refreshed, [b])
        XCTAssertTrue(model.noticeText?.contains("子目录刷新失败") == true)
        let cache = try await metadata.directoryCache(profileID: profileID, url: a)
        XCTAssertEqual(cache?.entries, StabilitySVNClient.entries)
        let aCount = await client.listCount(for: a)
        XCTAssertEqual(aCount, 1, "Duplicate expanded URLs are deduplicated")
        XCTAssertEqual(model.state, .loaded(root))
        XCTAssertFalse(model.isBusy)
    }

    func testNavigationSupersedesPendingExpandedRefresh() async throws {
        let client = ControlledListSVNClient()
        let model = BrowserViewModel(svnClient: client)
        let root = URL(string: "https://example.com/root")!
        let a = root.appendingPathComponent("a")
        let b = root.appendingPathComponent("b")
        let destination = URL(string: "https://example.com/new/root")!
        try await model.connect(to: root)
        var refreshed: [URL] = []
        model.onTreeDirectoryRefreshed = { url, _ in refreshed.append(url) }
        let refresh = Task { try await model.refresh(expandedDirectoryURLs: [a, b]) }
        await client.waitForRequest(a)
        await client.waitForRequest(b)
        try await model.navigate(to: destination)
        await client.resolve(a, result: .success([]))
        await client.resolve(b, result: .success([]))
        do { try await refresh.value; XCTFail("Expected obsolete refresh cancellation") }
        catch is CancellationError {}
        XCTAssertTrue(refreshed.isEmpty)
        let bCount = await client.listCount(for: b)
        XCTAssertEqual(bCount, 1)
        XCTAssertEqual(model.currentURL, destination)
        XCTAssertEqual(model.state, .loaded(destination))
        XCTAssertFalse(model.isBusy)
    }

    func testDirectoryCacheExpiresAtExactly25Minutes() {
        let date = Date(timeIntervalSince1970: 10000)
        let snapshot = DirectoryCacheSnapshot(entries: [], cachedAt: date)
        XCTAssertFalse(snapshot.isExpired(at: date.addingTimeInterval(1499.999)))
        XCTAssertTrue(snapshot.isExpired(at: date.addingTimeInterval(1500)))
        XCTAssertTrue(snapshot.isExpired(at: date.addingTimeInterval(1501)))
    }

    private func cachedPage(age: TimeInterval) async throws -> (BrowserViewModel, ControlledListSVNClient, RepositoryMetadataService, URL) {
        let metadata = RepositoryMetadataService(store: try RepositoryMetadataStore(inMemory: ()))
        let client = ControlledListSVNClient()
        let url = URL(string: "https://example.com/cached")!
        let profileID = UUID()
        try await metadata.replaceDirectoryCache(profileID: profileID, url: url,
            entries: StabilitySVNClient.entries, cachedAt: .now.addingTimeInterval(-age))
        let model = BrowserViewModel(svnClient: client, metadataService: metadata)
        try await model.connect(session: RepositorySession(profileID: profileID, displayName: "Cache",
            baseURL: url, options: .anonymous))
        return (model, client, metadata, url)
    }

    func testFreshDirectoryCacheAvoidsServerRead() async throws {
        let (model, client, _, _) = try await cachedPage(age: 24 * 60)
        for _ in 0..<100 { await Task.yield() }
        let count = await client.totalListCount
        XCTAssertEqual(count, 0)
        XCTAssertEqual(model.rows.map(\.name), StabilitySVNClient.entries.map(\.name))
        XCTAssertFalse(model.isBusy)
    }

    func testExpiredCacheDisplaysImmediatelyThenUpdatesInBackground() async throws {
        let (model, client, metadata, url) = try await cachedPage(age: 26 * 60)
        await client.waitForRequest(url)
        XCTAssertEqual(model.state, .loaded(url))
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.rows.map(\.name), StabilitySVNClient.entries.map(\.name))
        let updated = expectation(description: "Background result applied")
        let entries = [SVNListEntry(name: "fresh.txt", kind: .file, size: 3, revision: 10, author: nil, updatedAt: nil)]
        model.onChange = { if model.rows.first?.name == "fresh.txt" { updated.fulfill() } }
        await client.resolve(url, result: .success(entries))
        await fulfillment(of: [updated], timeout: 2)
        let snapshot = try await metadata.directoryCache(profileID: try XCTUnwrap(model.session?.profileID), url: url)
        XCTAssertEqual(snapshot?.entries, entries)
        XCTAssertFalse(try XCTUnwrap(snapshot).isExpired())
        XCTAssertEqual(model.rows.map(\.name), ["fresh.txt"])
        XCTAssertFalse(model.canGoBack, "Background refresh must not add navigation history")
        model.onChange = nil
    }

    func testBackgroundRefreshFailureKeepsExpiredCacheUsable() async throws {
        let (model, client, metadata, url) = try await cachedPage(age: 26 * 60)
        await client.waitForRequest(url)
        let failed = expectation(description: "Nonblocking refresh warning")
        model.onChange = { if model.noticeText?.contains("后台刷新失败") == true { failed.fulfill() } }
        await client.resolve(url, result: .failure(.connectionTimedOut))
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertEqual(model.state, .loaded(url))
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.rows.map(\.name), StabilitySVNClient.entries.map(\.name))
        let snapshot = try await metadata.directoryCache(profileID: try XCTUnwrap(model.session?.profileID), url: url)
        XCTAssertTrue(try XCTUnwrap(snapshot).isExpired())
        model.onChange = nil
    }

    func testLateBackgroundRefreshCannotReplaceNewDirectory() async throws {
        let (model, client, metadata, url) = try await cachedPage(age: 26 * 60)
        let profileID = try XCTUnwrap(model.session?.profileID)
        await client.waitForRequest(url)
        let newURL = URL(string: "https://example.com/root")!
        try await model.navigate(to: newURL)
        await client.resolve(url, result: .success([]))
        // Wait for the underlying shared cache update, not a guessed delay.
        for _ in 0..<1000 {
            if try await metadata.directoryCache(profileID: profileID, url: url)?.entries.isEmpty == true { break }
            await Task.yield()
        }
        XCTAssertEqual(model.currentURL, newURL)
        XCTAssertEqual(model.state, .loaded(newURL))
        XCTAssertEqual(model.rows.map(\.name), StabilitySVNClient.entries.map(\.name))
    }

    func testExpandedDirectoriesShowExpiredRowsAndCoalesceBackgroundReads() async throws {
        let metadata = RepositoryMetadataService(store: try RepositoryMetadataStore(inMemory: ()))
        let client = ControlledListSVNClient()
        let root = URL(string: "https://example.com/root")!
        let child = URL(string: "https://example.com/root/expired")!
        let profileID = UUID()
        let session = RepositorySession(profileID: profileID, displayName: "Tree", baseURL: root, options: .anonymous)
        let first = BrowserViewModel(svnClient: client, metadataService: metadata)
        let second = BrowserViewModel(svnClient: client, metadataService: metadata)
        try await first.connect(session: session)
        try await second.connect(session: session)
        try await metadata.replaceDirectoryCache(profileID: profileID, url: child,
            entries: StabilitySVNClient.entries, cachedAt: .now.addingTimeInterval(-26 * 60))
        let updatedFirst = expectation(description: "First tree refreshed")
        let updatedSecond = expectation(description: "Second tree refreshed")
        first.onTreeDirectoryRefreshed = { url, rows in
            XCTAssertEqual(url, child); XCTAssertTrue(rows.isEmpty); updatedFirst.fulfill()
        }
        second.onTreeDirectoryRefreshed = { url, rows in
            XCTAssertEqual(url, child); XCTAssertTrue(rows.isEmpty); updatedSecond.fulfill()
        }
        let firstRows = try await first.rows(in: child)
        let secondRows = try await second.rows(in: child)
        _ = try await first.rows(in: child)
        XCTAssertEqual(firstRows, secondRows)
        XCTAssertFalse(firstRows.isEmpty)
        await client.waitForRequest(child)
        for _ in 0..<100 { await Task.yield() }
        let count = await client.listCount(for: child)
        XCTAssertEqual(count, 1)
        await client.resolve(child, result: .success([]))
        await fulfillment(of: [updatedFirst, updatedSecond], timeout: 2)
        let snapshot = try await metadata.directoryCache(profileID: profileID, url: child)
        XCTAssertTrue(try XCTUnwrap(snapshot).entries.isEmpty)
    }

    func testCacheInvalidationPreventsLateBackgroundResultFromResurrectingEntries() async throws {
        try await assertBackgroundCacheReplacement(clearCache: true)
    }

    func testCredentialCacheInvalidationCancelsAnOlderDirectoryRefresh() async throws {
        let metadata = RepositoryMetadataService(store: try RepositoryMetadataStore(inMemory: ()))
        let client = ControlledListSVNClient()
        let url = URL(string: "https://example.com/private")!
        let profileID = UUID()
        let refresh = Task {
            try await metadata.refreshDirectoryCache(profileID: profileID, url: url) {
                try await client.list(url: url, options: .anonymous)
            }
        }
        await client.waitForRequest(url)

        try await metadata.clearRepositoryCache(profileID: profileID)
        await client.resolve(url, result: .success(StabilitySVNClient.entries))

        do { _ = try await refresh.value; XCTFail("Expected old-credential refresh cancellation") }
        catch is CancellationError {}
        let snapshot = try await metadata.directoryCache(profileID: profileID, url: url)
        XCTAssertNil(snapshot)
    }

    func testExplicitCacheReplacementWinsOverLateBackgroundResult() async throws {
        try await assertBackgroundCacheReplacement(clearCache: false)
    }

    func testSearchIndexHydrationCancelsOlderBackgroundDirectoryRefresh() async throws {
        let metadata = RepositoryMetadataService(store: try RepositoryMetadataStore(inMemory: ()))
        let client = ControlledListSVNClient()
        let profileID = UUID()
        let root = URL(string: "https://example.com/root/")!
        let child = root.appendingPathComponent("folder", isDirectory: true)
        let refresh = Task {
            try await metadata.refreshDirectoryCache(profileID: profileID, url: child) {
                try await client.list(url: child, options: .anonymous)
            }
        }
        await client.waitForRequest(child)
        let directory = SearchIndexEntry(profileID: profileID, rootURL: root, url: child,
            name: "folder", kind: .directory, size: nil, revision: 9, author: nil, modifiedAt: nil)
        let file = SearchIndexEntry(profileID: profileID, rootURL: root,
            url: child.appendingPathComponent("fresh.txt"), name: "fresh.txt", kind: .file,
            size: 3, revision: 10, author: nil, modifiedAt: nil)
        try await metadata.replaceSearchIndex(profileID: profileID, rootURL: root,
            entries: [directory, file])
        await client.resolve(child, result: .success([]))
        do { _ = try await refresh.value; XCTFail("Expected older directory refresh cancellation") }
        catch is CancellationError {}
        let cache = try await metadata.directoryCache(profileID: profileID, url: child)
        XCTAssertEqual(cache?.entries.map(\.name), ["fresh.txt"])
    }

    private func assertBackgroundCacheReplacement(clearCache: Bool) async throws {
        let metadata = RepositoryMetadataService(store: try RepositoryMetadataStore(inMemory: ()))
        let client = ControlledListSVNClient()
        let url = URL(string: "https://example.com/background")!
        let profileID = UUID()
        let refresh = Task {
            try await metadata.refreshDirectoryCache(profileID: profileID, url: url) {
                try await client.list(url: url, options: .anonymous)
            }
        }
        await client.waitForRequest(url)
        if clearCache {
            try await metadata.clearDirectoryCache(profileID: profileID)
        } else {
            try await metadata.replaceDirectoryCache(profileID: profileID, url: url, entries: StabilitySVNClient.entries)
        }
        await client.resolve(url, result: .success([]))
        do { _ = try await refresh.value; XCTFail("Expected superseded background refresh cancellation") }
        catch is CancellationError {}
        let snapshot = try await metadata.directoryCache(profileID: profileID, url: url)
        if clearCache { XCTAssertNil(snapshot) }
        else { XCTAssertEqual(snapshot?.entries, StabilitySVNClient.entries) }
    }

    func testFailedServerSwitchClearsOldLocationAndDisablesWrites() async throws {
        let client = StabilitySVNClient()
        let model = BrowserViewModel(svnClient: client)
        try await model.connect(to: URL(string: "https://example.com/root")!)
        await client.setFailLists(true)
        do {
            try await model.connect(to: URL(string: "https://other.example/root")!)
            XCTFail("Expected failure")
        } catch SVNClientError.connectionTimedOut {}
        XCTAssertNil(model.session)
        XCTAssertNil(model.currentURL)
        XCTAssertTrue(model.rows.isEmpty)
        let controller = BrowserViewController(viewModel: model)
        XCTAssertFalse(controller.canModifyRepository)
        do {
            _ = try await model.createDirectory(name: "wrong-target", message: "must not write")
            XCTFail("Expected disconnected write rejection")
        } catch SVNClientError.unsupportedOperation {}
        let count = await client.writeCount
        XCTAssertEqual(count, 0)
    }

    func testSupersededConnectionSuccessDoesNotOverwriteNewSession() async throws {
        try await assertSupersededConnection(result: .success([]))
    }

    func testSupersededConnectionFailureDoesNotOverwriteNewSession() async throws {
        try await assertSupersededConnection(result: .failure(.connectionTimedOut))
    }

    func testSupersededCancelledConnectionDoesNotRestoreOldState() async throws {
        try await assertSupersededConnection(result: .success([]), cancelOld: true)
    }

    private func assertSupersededConnection(
        result: Result<[SVNListEntry], SVNClientError>, cancelOld: Bool = false
    ) async throws {
        let client = ControlledListSVNClient()
        let model = BrowserViewModel(svnClient: client)
        let oldURL = URL(string: "https://old.example/slow")!
        let newURL = URL(string: "https://new.example/fast")!
        let old = Task { try await model.connect(to: oldURL) }
        await client.waitForRequest(oldURL)
        let new = Task { try await model.connect(to: newURL) }
        await client.waitForRequest(newURL)
        await client.resolve(newURL, result: .success(StabilitySVNClient.entries))
        try await new.value
        if cancelOld { old.cancel() }
        await client.resolve(oldURL, result: result)
        do { try await old.value; XCTFail("Expected obsolete request cancellation") }
        catch is CancellationError {}
        XCTAssertEqual(model.session?.baseURL, newURL)
        XCTAssertEqual(model.currentURL, newURL)
        XCTAssertEqual(model.state, .loaded(newURL))
        XCTAssertEqual(model.rows.map(\.name), StabilitySVNClient.entries.map(\.name))
        XCTAssertFalse(model.isBusy)
    }

    func testOldFailureCannotClearNewConnectionLoadingFlags() async throws {
        let client = ControlledListSVNClient()
        let model = BrowserViewModel(svnClient: client)
        let oldURL = URL(string: "https://example.com/old")!
        let newURL = URL(string: "https://example.com/new")!
        let old = Task { try await model.connect(to: oldURL) }
        await client.waitForRequest(oldURL)
        let new = Task { try await model.connect(to: newURL) }
        await client.waitForRequest(newURL)
        await client.resolve(oldURL, result: .failure(.connectionTimedOut))
        do { try await old.value; XCTFail("Expected obsolete cancellation") } catch is CancellationError {}
        XCTAssertTrue(model.isBusy)
        XCTAssertTrue(model.isCancellable)
        XCTAssertEqual(model.state, .loading)
        XCTAssertEqual(model.session?.baseURL, newURL)
        await client.resolve(newURL, result: .success([]))
        try await new.value
    }

    func testDisconnectPreventsPendingRequestFromResurrectingSession() async throws {
        let client = ControlledListSVNClient()
        let model = BrowserViewModel(svnClient: client)
        let url = URL(string: "https://example.com/pending")!
        let task = Task { try await model.connect(to: url) }
        await client.waitForRequest(url)
        model.disconnect(profileID: try XCTUnwrap(model.session?.profileID))
        await client.resolve(url, result: .success(StabilitySVNClient.entries))
        do { try await task.value; XCTFail("Expected obsolete cancellation") } catch is CancellationError {}
        XCTAssertNil(model.session)
        XCTAssertNil(model.currentURL)
        XCTAssertEqual(model.state, .disconnected)
        XCTAssertTrue(model.rows.isEmpty)
    }

    func testCancellingCurrentConnectionLeavesNoOldWriteTarget() async throws {
        let client = ControlledListSVNClient()
        let model = BrowserViewModel(svnClient: client)
        try await model.connect(to: URL(string: "https://example.com/root")!)
        let url = URL(string: "https://example.com/pending")!
        let task = Task { try await model.connect(to: url) }
        await client.waitForRequest(url)
        task.cancel()
        await client.resolve(url, result: .success([]))
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertNil(model.session)
        XCTAssertNil(model.currentURL)
        XCTAssertEqual(model.state, .disconnected)
    }

    func testOverlappingNavigationKeepsLatestDirectoryAndCorrectBackStack() async throws {
        let client = ControlledListSVNClient()
        let model = BrowserViewModel(svnClient: client)
        let root = URL(string: "https://example.com/root")!
        let oldURL = URL(string: "https://example.com/old")!
        let newURL = URL(string: "https://example.com/new")!
        try await model.connect(to: root)
        let old = Task { try await model.navigate(to: oldURL) }
        await client.waitForRequest(oldURL)
        let new = Task { try await model.navigate(to: newURL) }
        await client.waitForRequest(newURL)
        await client.resolve(newURL, result: .success([]))
        try await new.value
        await client.resolve(oldURL, result: .success([]))
        do { try await old.value; XCTFail("Expected obsolete cancellation") } catch is CancellationError {}
        XCTAssertEqual(model.currentURL, newURL)
        try await model.goBack()
        XCTAssertEqual(model.currentURL, root)
        XCTAssertFalse(model.canGoBack)
    }

    func testCreateReturnsCommittedRevisionEvenIfRefreshFails() async throws { try await assertCommittedWrite(.create) }

    func testLatePostCommitRefreshFailureCannotClearNewDirectory() async throws {
        let client = ControlledListSVNClient()
        let model = BrowserViewModel(svnClient: client)
        let initialURL = URL(string: "https://example.com/initial")!
        let destination = URL(string: "https://example.com/destination")!
        let connection = Task { try await model.connect(to: initialURL) }
        await client.waitForRequest(initialURL)
        await client.resolve(initialURL, result: .success(StabilitySVNClient.entries))
        try await connection.value
        let write = Task { try await model.createDirectory(name: "new", message: "new") }
        await client.waitForRequest(initialURL)
        let navigation = Task { try await model.navigate(to: destination) }
        await client.waitForRequest(destination)
        await client.resolve(destination, result: .success(StabilitySVNClient.entries))
        try await navigation.value
        await client.resolve(initialURL, result: .failure(.connectionTimedOut))
        let result = try await write.value
        XCTAssertEqual(result.revision, 42)
        XCTAssertEqual(model.currentURL, destination)
        XCTAssertEqual(model.state, .loaded(destination))
        XCTAssertEqual(model.rows.map(\.name), StabilitySVNClient.entries.map(\.name))
        XCTAssertFalse(model.isBusy)
    }
    func testRenameSyncsFavoritesEvenIfRefreshFails() async throws { try await assertCommittedWrite(.rename) }
    func testDeleteMarksFavoritesUnavailableEvenIfRefreshFails() async throws { try await assertCommittedWrite(.delete) }
    func testUploadReturnsCommittedRevisionEvenIfRefreshFails() async throws { try await assertCommittedWrite(.upload) }
    func testReplaceReturnsCommittedRevisionEvenIfRefreshFails() async throws { try await assertCommittedWrite(.replace) }
    func testRestoreReturnsCommittedRevisionEvenIfRefreshFails() async throws { try await assertCommittedWrite(.restore) }

    private enum WriteCase { case create, rename, delete, upload, replace, restore }

    private func assertCommittedWrite(_ operation: WriteCase) async throws {
        let store = try RepositoryMetadataStore(inMemory: ())
        let metadata = RepositoryMetadataService(store: store)
        let client = StabilitySVNClient()
        let model = BrowserViewModel(svnClient: client, metadataService: metadata)
        try await model.connect(to: URL(string: "https://example.com/root")!)
        let row = try XCTUnwrap(model.rows.first(where: { $0.kind == .file }))
        _ = try await model.setFavorites([row], isFavorite: true)
        await client.setFailLists(true)
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("local-\(UUID()).txt")
        try Data("new".utf8).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        let result: SVNWriteResult
        switch operation {
        case .create: result = try await model.createDirectory(name: "new", message: "new")
        case .rename: result = try await model.rename(row, to: "renamed.txt", message: "rename")
        case .delete: result = try await model.delete(row, message: "delete")
        case .upload: result = try await model.upload(files: [local], message: "upload")
        case .replace: result = try await model.replace(row, with: local, message: "replace")
        case .restore:
            let history = BrowserFileHistory(profileID: try XCTUnwrap(model.session?.profileID),
                sourceURL: row.url, displayName: row.name, currentRevision: 4, pegRevision: 9,
                entries: [SVNLogEntry(revision: 2, author: nil, date: nil, message: "old")], options: .anonymous)
            result = try await model.restore(history: history, revision: 2, message: "restore")
        }
        XCTAssertEqual(result.revision, 42)
        let count = await client.writeCount
        XCTAssertEqual(count, 1, "No automatic write retry after a read failure")
        XCTAssertTrue(model.noticeText?.contains("r42") == true)
        XCTAssertTrue(model.noticeText?.contains("已提交成功") == true)
        XCTAssertTrue(model.noticeText?.contains("不要重复提交") == true)
        XCTAssertTrue(model.rows.isEmpty, "Pre-commit rows must not remain actionable")
        let favorites = try await metadata.favorites()
        if operation == .rename {
            XCTAssertEqual(favorites.first?.url.lastPathComponent, "renamed.txt")
        } else if operation == .delete {
            XCTAssertEqual(favorites.first?.isAvailable, false)
        }
    }

    func testEditableOpenCopiesCannotContaminateHistoricalSnapshotsOrBeDeletedWhileModified() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let openDocumentsRoot = root.appendingPathComponent("OpenDocuments", isDirectory: true)
        let abandoned = openDocumentsRoot.appendingPathComponent("abandoned", isDirectory: true)
        let recent = openDocumentsRoot.appendingPathComponent("recent", isDirectory: true)
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recent, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-8 * 24 * 60 * 60)],
            ofItemAtPath: abandoned.path
        )
        let client = StabilitySVNClient()
        let model = BrowserViewModel(svnClient: client, cacheRootURL: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        try await model.connect(to: URL(string: "https://example.com/root")!)
        let row = try XCTUnwrap(model.rows.first(where: { $0.kind == .file }))
        let history = BrowserFileHistory(profileID: try XCTUnwrap(model.session?.profileID),
            sourceURL: row.url, displayName: row.name, currentRevision: 4, pegRevision: 9,
            entries: [SVNLogEntry(revision: 4, author: nil, date: nil, message: "four")], options: .anonymous)
        let firstCopy = try await model.localURLForOpening(row)
        try Data("edited locally".utf8).write(to: firstCopy)
        let snapshot = try await model.localSnapshotURL(history: history, revision: 4)
        let secondCopy = try await model.localURLForOpening(history: history, revision: 4)
        XCTAssertNotEqual(firstCopy, snapshot)
        XCTAssertNotEqual(firstCopy, secondCopy)
        XCTAssertEqual(try String(contentsOf: snapshot, encoding: .utf8), "r4")
        XCTAssertEqual(try String(contentsOf: secondCopy, encoding: .utf8), "r4")
        let permissions = try FileManager.default.attributesOfItem(atPath: snapshot.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o444)
        let exports = await client.exportCount
        XCTAssertEqual(exports, 1, "An immutable snapshot is still reusable")
        let sessionDirectory = firstCopy.deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDirectory.path))
        model.cleanupOpenDocumentCopies()
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstCopy.path), "Unsaved edits must survive app cleanup")
        XCTAssertEqual(model.modifiedOpenDocuments.map(\.localURL), [firstCopy])
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path), "Cleanup must only remove this app session")
    }

    func testOpenDocumentChangesCanBeUploadedAndRepeatedOpenReusesTheSameCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("open-upload-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = StabilitySVNClient()
        let model = BrowserViewModel(svnClient: client, cacheRootURL: root)
        try await model.connect(to: URL(string: "https://example.com/root")!)
        let row = try XCTUnwrap(model.rows.first(where: { $0.kind == .file }))

        let firstOpen = try await model.localURLForOpening(row)
        let repeatedOpen = try await model.localURLForOpening(row)
        XCTAssertEqual(firstOpen, repeatedOpen)
        XCTAssertTrue(model.modifiedOpenDocuments.isEmpty)

        try Data("edited once".utf8).write(to: firstOpen)
        let firstChange = try XCTUnwrap(model.modifiedOpenDocuments.first)
        XCTAssertTrue(firstChange.canUpload)
        _ = try await model.uploadOpenDocumentChanges(id: firstChange.id, message: "first edit")
        XCTAssertTrue(model.modifiedOpenDocuments.isEmpty)
        let firstExpectedRevision = await client.lastReplaceExpectedRevision
        let firstContents = await client.lastReplaceContents
        XCTAssertEqual(firstExpectedRevision, 4)
        XCTAssertEqual(firstContents, "edited once")

        try Data("edited twice".utf8).write(to: firstOpen)
        let secondChange = try XCTUnwrap(model.modifiedOpenDocuments.first)
        _ = try await model.uploadOpenDocumentChanges(id: secondChange.id, message: "second edit")
        let secondExpectedRevision = await client.lastReplaceExpectedRevision
        XCTAssertEqual(secondExpectedRevision, 42, "The successful commit revision becomes the next concurrency check")

        model.cleanupOpenDocumentCopies()
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstOpen.path), "Clean editing copies can be removed")
    }

    func testDiscardLocalChangesRestoresLastDownloadedOrCommittedContents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("open-reset-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = StabilitySVNClient()
        let model = BrowserViewModel(svnClient: client, cacheRootURL: root)
        try await model.connect(to: URL(string: "https://example.com/root")!)
        let row = try XCTUnwrap(model.rows.first(where: { $0.kind == .file }))
        let localURL = try await model.localURLForOpening(row)

        try Data("discard this".utf8).write(to: localURL)
        XCTAssertTrue(model.hasLocalChanges(for: row))
        try model.discardLocalChanges(for: row)
        XCTAssertFalse(model.hasLocalChanges(for: row))
        XCTAssertEqual(try String(contentsOf: localURL, encoding: .utf8), "r4")

        try Data("committed baseline".utf8).write(to: localURL)
        let change = try XCTUnwrap(model.modifiedOpenDocuments.first)
        _ = try await model.uploadOpenDocumentChanges(id: change.id, message: "commit baseline")
        try Data("second uncommitted edit".utf8).write(to: localURL)
        try model.discardLocalChanges(for: row)
        XCTAssertEqual(try String(contentsOf: localURL, encoding: .utf8), "committed baseline")
        XCTAssertFalse(model.hasLocalChanges(for: row))
    }

    func testModifiedOpenDocumentIsRecoveredAfterRelaunchAndReenabledAfterReconnect() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("open-recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = StabilitySVNClient()
        let profileID = UUID()
        let repositoryURL = URL(string: "https://example.com/root")!
        let originalSession = RepositorySession(
            profileID: profileID,
            displayName: "Documents",
            baseURL: repositoryURL,
            options: .anonymous
        )
        var firstModel: BrowserViewModel? = BrowserViewModel(svnClient: client, cacheRootURL: root)
        try await firstModel?.connect(session: originalSession)
        let row = try XCTUnwrap(firstModel?.rows.first(where: { $0.kind == .file }))
        let localURL = try await firstModel?.localURLForOpening(row)
        try Data("recovered edit".utf8).write(to: try XCTUnwrap(localURL))
        firstModel = nil

        let relaunchedModel = BrowserViewModel(svnClient: client, cacheRootURL: root)
        let recoveredBeforeConnect = try XCTUnwrap(relaunchedModel.modifiedOpenDocuments.first)
        XCTAssertEqual(
            recoveredBeforeConnect.localURL.resolvingSymlinksInPath(),
            localURL?.resolvingSymlinksInPath()
        )
        XCTAssertFalse(recoveredBeforeConnect.canUpload)

        try await relaunchedModel.connect(session: originalSession)
        let recoveredAfterConnect = try XCTUnwrap(relaunchedModel.modifiedOpenDocuments.first)
        XCTAssertTrue(recoveredAfterConnect.canUpload)
        _ = try await relaunchedModel.uploadOpenDocumentChanges(
            id: recoveredAfterConnect.id,
            message: "recover"
        )
        XCTAssertTrue(relaunchedModel.modifiedOpenDocuments.isEmpty)
        let contents = await client.lastReplaceContents
        XCTAssertEqual(contents, "recovered edit")
    }

    func testSnapshotCacheIncludesFullSourceURLWhenProfileIsEdited() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-host-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = StabilitySVNClient()
        let model = BrowserViewModel(svnClient: client, cacheRootURL: root)
        let profileID = UUID()
        for host in ["first.example", "second.example"] {
            let url = URL(string: "https://\(host)/root")!
            try await model.connect(session: RepositorySession(profileID: profileID, displayName: host,
                baseURL: url, options: .anonymous))
            _ = try await model.localSnapshotURL(for: try XCTUnwrap(model.rows.first(where: { $0.kind == .file })))
        }
        let exports = await client.exportCount
        XCTAssertEqual(exports, 2, "Different hosts cannot reuse the same path/revision cache")
    }

    func testFinderPromisesExcludeSelectedDescendantsButKeepIndependentItems() async throws {
        let model = BrowserViewModel(svnClient: StabilitySVNClient())
        try await model.connect(to: URL(string: "https://example.com/root")!)
        let controller = BrowserViewController(viewModel: model)
        _ = controller.view
        let scroll = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? NSScrollView }.first)
        let outline = try XCTUnwrap(scroll.documentView as? NSOutlineView)
        let parent = try XCTUnwrap(outline.item(atRow: 0))
        outline.expandItem(parent)
        for _ in 0..<1000 {
            if let child = outline.item(atRow: 1),
               (controller.outlineView(outline, viewFor: outline.tableColumns[0], item: child) as? NSTableCellView)?.textField?.stringValue == "child.txt" { break }
            await Task.yield()
        }
        let child = try XCTUnwrap(outline.item(atRow: 1))
        let peer = try XCTUnwrap(outline.item(atRow: 2))
        let childName = (controller.outlineView(outline, viewFor: outline.tableColumns[0], item: child) as? NSTableCellView)?.textField?.stringValue
        XCTAssertEqual(childName, "child.txt", "Child must be fully loaded, not a placeholder")
        outline.selectRowIndexes(IndexSet([0, 1, 2]), byExtendingSelection: false)
        XCTAssertNotNil(controller.outlineView(outline, pasteboardWriterForItem: parent))
        XCTAssertNil(controller.outlineView(outline, pasteboardWriterForItem: child))
        XCTAssertNotNil(controller.outlineView(outline, pasteboardWriterForItem: peer))
        outline.selectRowIndexes(IndexSet([1]), byExtendingSelection: false)
        XCTAssertNotNil(controller.outlineView(outline, pasteboardWriterForItem: child), "Child alone remains downloadable")
    }

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
        try await viewModel.search(query: "api")

        XCTAssertTrue(viewModel.isShowingSearchResults)
        XCTAssertEqual(viewModel.rows.map(\.name), ["API-Guide.txt"])
        XCTAssertEqual(viewModel.rows.first?.location, "")
        XCTAssertNotNil(viewModel.searchIndexedAt)
        XCTAssertTrue(viewModel.statusText.contains("索引更新于"))
        let firstRecursiveListCount = await client.recursiveListCount
        XCTAssertEqual(firstRecursiveListCount, 1)
        _ = try await viewModel.localURLForOpening(try XCTUnwrap(viewModel.rows.first))
        let liveInfoCount = await client.infoCount
        let liveExportRevision = await client.lastExportRevision
        XCTAssertEqual(liveInfoCount, 1, "Opening an indexed result must validate it against the server")
        XCTAssertEqual(liveExportRevision, 5, "The validated live revision must replace the stale indexed revision")

        viewModel.clearSearch()
        try await viewModel.navigate(to: rootURL)
        try await viewModel.search(query: "api")
        XCTAssertEqual(Set(viewModel.rows.map(\.name)), ["API-Guide.txt", "api-plan.txt"])
        let secondRecursiveListCount = await client.recursiveListCount
        XCTAssertEqual(secondRecursiveListCount, 2, "Each current directory owns its local index")
        viewModel.clearSearch()
        XCTAssertEqual(Set(viewModel.rows.map(\.name)), ["技术部", "市场部", "README.txt"],
            "The recursive index must refresh the visible directory cache")
        try await viewModel.search(query: "api")
        let repeatedRecursiveListCount = await client.recursiveListCount
        XCTAssertEqual(repeatedRecursiveListCount, 2, "A repeated search in the same directory reuses its index")
        try await metadata.replaceSearchIndex(
            profileID: profile.id,
            rootURL: rootURL,
            entries: [],
            indexedAt: .now.addingTimeInterval(-26 * 60)
        )
        try await viewModel.search(query: "api")
        let expiredRecursiveListCount = await client.recursiveListCount
        XCTAssertEqual(expiredRecursiveListCount, 3, "An expired index rebuilds automatically without a toolbar button")
        XCTAssertEqual(Set(viewModel.rows.map(\.name)), ["API-Guide.txt", "api-plan.txt"])
    }

    func testConcurrentSearchesReuseAnInFlightIndexRefresh() async throws {
        let store = try RepositoryMetadataStore(inMemory: ())
        let metadata = RepositoryMetadataService(store: store)
        let client = CoalescingSearchSVNClient()
        let viewModel = BrowserViewModel(svnClient: client, metadataService: metadata)
        let rootURL = try XCTUnwrap(URL(string: "https://svn.example.com/repo/"))

        try await viewModel.connect(to: rootURL)
        let first = Task { @MainActor in try await viewModel.search(query: "api") }
        await client.waitForRecursiveRequestCount(1)
        let second = Task { @MainActor in try await viewModel.search(query: "readme") }
        for _ in 0..<100 { await Task.yield() }

        let countWhileBothSearchesAreWaiting = await client.recursiveListCount
        XCTAssertEqual(countWhileBothSearchesAreWaiting, 1)
        await client.resolveRecursiveRequests()
        _ = try? await first.value
        try await second.value

        let finalRecursiveListCount = await client.recursiveListCount
        XCTAssertEqual(finalRecursiveListCount, 1)
        XCTAssertEqual(viewModel.rows.map(\.name), ["README.txt"])
    }

    func testToolbarSearchOnlySubmitsTheWholeString() throws {
        let viewModel = BrowserViewModel(svnClient: MockSVNClient(result: .success([])))
        let browser = BrowserViewController(viewModel: viewModel)
        let windowController = MainWindowController(
            sidebarViewController: SidebarViewController(userDefaults: UserDefaults(suiteName: UUID().uuidString)!),
            browserViewController: browser
        )
        let searchItem = try XCTUnwrap(
            windowController.window?.toolbar?.items.first { $0.itemIdentifier.rawValue == "Search" }
        )
        let searchField = try XCTUnwrap(searchItem.view as? NSSearchField)

        XCTAssertFalse(searchField.sendsSearchStringImmediately)
        XCTAssertTrue(searchField.sendsWholeSearchString)
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

    func testBatchFavoritesUpdateAllRowsWithOneViewModelOperation() async throws {
        let store = try RepositoryMetadataStore(inMemory: ())
        let metadata = RepositoryMetadataService(store: store)
        let viewModel = BrowserViewModel(svnClient: SearchSVNClient(), metadataService: metadata)
        let rootURL = try XCTUnwrap(URL(string: "https://svn.example.com/repo/"))
        let profile = RepositoryProfile(
            id: UUID(), displayName: "公司文档", baseURL: rootURL, username: "",
            certificatePolicy: .strict, createdAt: .now, updatedAt: .now
        )
        try await viewModel.connect(profile: profile, password: nil)

        let rows = viewModel.rows
        let addedCount = try await viewModel.setFavorites(rows, isFavorite: true)
        XCTAssertEqual(addedCount, rows.count)
        XCTAssertEqual(viewModel.noticeText, "已添加 \(rows.count) 项到收藏")
        XCTAssertTrue(rows.allSatisfy(viewModel.isFavorite))
        let storedFavoriteCount = try await metadata.favorites().count
        XCTAssertEqual(storedFavoriteCount, rows.count)

        let removedCount = try await viewModel.setFavorites([rows[0]], isFavorite: false)
        XCTAssertEqual(removedCount, 1)
        XCTAssertFalse(viewModel.isFavorite(rows[0]))
        XCTAssertTrue(viewModel.isFavorite(rows[1]))
    }

    func testBatchDeleteSendsAllTargetsAsOneWrite() async throws {
        let client = BatchDeleteSVNClient()
        let viewModel = BrowserViewModel(svnClient: client)
        let rootURL = try XCTUnwrap(URL(string: "https://svn.example.com/repo/"))
        try await viewModel.connect(to: rootURL)
        let rows = viewModel.rows

        let result = try await viewModel.delete(rows, message: "删除 2 项")
        let deletedURLBatches = await client.deletedURLBatches
        let deleteMessages = await client.deleteMessages

        XCTAssertEqual(result.revision, 18)
        XCTAssertEqual(deletedURLBatches, [rows.map(\.url)])
        XCTAssertEqual(deleteMessages, ["删除 2 项"])
        XCTAssertEqual(viewModel.noticeText, "已删除 2 项 · r18")
    }

    func testBatchDownloadContinuesAfterAnItemFailsAndReportsSummary() async throws {
        let client = BatchDownloadSVNClient()
        let viewModel = BrowserViewModel(svnClient: client)
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("batch-download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let successURL = try XCTUnwrap(URL(string: "https://svn.example.com/repo/成功.txt"))
        let failureURL = try XCTUnwrap(URL(string: "https://svn.example.com/repo/失败.txt"))
        let items = [successURL, failureURL].map { sourceURL in
            BrowserBatchDownloadItem(
                request: BrowserDownloadRequest(
                    sourceURL: sourceURL,
                    displayName: sourceURL.lastPathComponent,
                    byteSize: 10,
                    revision: 3,
                    options: .anonymous
                ),
                destinationURL: directoryURL.appendingPathComponent(sourceURL.lastPathComponent),
                overwrite: false
            )
        }

        do {
            try await viewModel.download(items, to: directoryURL)
            XCTFail("Expected one failed download")
        } catch let failure as BrowserBatchDownloadFailure {
            XCTAssertEqual(failure.completedCount, 1)
            XCTAssertEqual(failure.failures, ["失败.txt"])
        }

        let exportedNames = await client.exportedNames
        XCTAssertEqual(exportedNames, ["成功.txt", "失败.txt"])
        guard case .failed = viewModel.transfers.first?.state else {
            return XCTFail("Expected a failed parent transfer")
        }
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

    func testTreeChildrenUseDirectoryCacheAndNestedWritesUseTheirActualParent() async throws {
        let store = try RepositoryMetadataStore(inMemory: ())
        let metadata = RepositoryMetadataService(store: store)
        let client = TreeOperationsSVNClient()
        let viewModel = BrowserViewModel(svnClient: client, metadataService: metadata)
        let rootURL = try XCTUnwrap(URL(string: "https://svn.example.com/repo/"))
        let profile = RepositoryProfile(
            id: UUID(), displayName: "公司文档", baseURL: rootURL, username: "",
            certificatePolicy: .strict, createdAt: .now, updatedAt: .now
        )
        try await viewModel.connect(profile: profile, password: nil)
        let directory = try XCTUnwrap(viewModel.rows.first)

        let firstChildren = try await viewModel.rows(in: directory.url)
        let secondChildren = try await viewModel.rows(in: directory.url)

        XCTAssertEqual(firstChildren, secondChildren)
        let directoryListCount = await client.listCount(for: directory.url)
        XCTAssertEqual(directoryListCount, 1)
        let nestedFile = try XCTUnwrap(firstChildren.first)
        _ = try await viewModel.rename(nestedFile, to: "新版.txt", message: "重命名")
        let move = await client.lastMove
        XCTAssertEqual(move?.sourceURL, directory.url.appendingPathComponent("旧版.txt"))
        XCTAssertEqual(move?.destinationURL, directory.url.appendingPathComponent("新版.txt"))

        let localFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("tree-upload-\(UUID().uuidString).txt")
        try Data("upload".utf8).write(to: localFile)
        defer { try? FileManager.default.removeItem(at: localFile) }
        _ = try await viewModel.upload(files: [localFile], to: directory.url, message: "上传")
        let uploadDirectory = await client.lastUploadDirectory
        XCTAssertEqual(uploadDirectory, directory.url)
        _ = try await viewModel.createDirectory(name: "子目录", in: directory.url, message: "新建")
        let createdDirectoryURL = await client.lastCreatedDirectoryURL
        XCTAssertEqual(createdDirectoryURL, directory.url.appendingPathComponent("子目录", isDirectory: true))
        XCTAssertGreaterThan(viewModel.directoryTreeGeneration, 0)
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
        XCTAssertEqual(transfer.stage, .finalizing)
        XCTAssertEqual(transfer.outputURL, destination)
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
        while viewModel.transfers.first?.stage != .downloading { await Task.yield() }

        XCTAssertEqual(viewModel.transfers.first?.stage, .downloading)
        XCTAssertFalse(viewModel.isBusy, "A background download must not block directory browsing")
        let transfer = try XCTUnwrap(viewModel.transfers.first)
        XCTAssertTrue(transfer.canCancel)

        viewModel.cancelTransfer(id: transfer.id)
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertEqual(viewModel.transfers.first?.state, .cancelled)
        XCTAssertEqual(viewModel.activeTransferCount, 0)
    }

    func testBatchUploadPlanSkipsOnlyConflicts() {
        let first = URL(fileURLWithPath: "/tmp/already.txt")
        let second = URL(fileURLWithPath: "/tmp/new.txt")
        let duplicateA = URL(fileURLWithPath: "/tmp/a/duplicate.txt")
        let duplicateB = URL(fileURLWithPath: "/tmp/b/duplicate.txt")

        let plan = makeBrowserUploadPlan(
            files: [first, second, duplicateA, duplicateB],
            existingNames: ["already.txt"]
        )

        XCTAssertEqual(plan.uploadableFiles, [second])
        XCTAssertEqual(plan.conflictNames, ["already.txt", "duplicate.txt"])
    }

    func testFailedDownloadCanBeRetriedWithOriginalRequestAndDestination() async throws {
        let client = RetryDownloadSVNClient()
        let viewModel = BrowserViewModel(svnClient: client)
        let rootURL = try XCTUnwrap(URL(string: "https://svn.example.com/repo/"))
        try await viewModel.connect(to: rootURL)
        let row = try XCTUnwrap(viewModel.rows.first)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("retry-transfer-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: destination) }

        do {
            try await viewModel.download(row, to: destination, overwrite: false)
            XCTFail("Expected first download to fail")
        } catch {
            // The failed task remains available in transfer history.
        }

        let failedTransfer = try XCTUnwrap(viewModel.transfers.first)
        XCTAssertTrue(failedTransfer.canRetry)
        XCTAssertEqual(failedTransfer.outputURL, destination)
        try await viewModel.retryTransfer(id: failedTransfer.id)

        XCTAssertEqual(viewModel.transfers.first?.state, .completed)
        let exportCount = await client.exportCount
        XCTAssertEqual(exportCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
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

private actor ExpandedRefreshSVNClient: SVNClient {
    private var updated = false
    private(set) var counts: [String: Int] = [:]
    func setUpdated() { updated = true }
    func version() async throws -> String { "1.14.5" }
    func list(url: URL, options: SVNRequestOptions) async throws -> [SVNListEntry] {
        let name = url.lastPathComponent
        counts[name, default: 0] += 1
        func entry(_ name: String, _ kind: SVNListEntry.Kind) -> SVNListEntry {
            SVNListEntry(name: name, kind: kind, size: nil, revision: updated ? 10 : 4, author: nil, updatedAt: nil)
        }
        switch name {
        case "root": return [entry("expanded", .directory), entry("closed", .directory)]
        case "expanded": return [entry("nested", .directory), entry("keep.txt", .file)]
        case "nested": return [entry(updated ? "new-leaf.txt" : "old-leaf.txt", .file)]
        default: return []
        }
    }
}

private actor ControlledListSVNClient: SVNClient {
    private var pending: [URL: CheckedContinuation<[SVNListEntry], Error>] = [:]
    private var listCounts: [URL: Int] = [:]
    var totalListCount: Int { listCounts.values.reduce(0, +) }
    func listCount(for url: URL) -> Int { listCounts[url, default: 0] }
    func version() async throws -> String { "1.14.5" }
    func makeDirectory(url: URL, message: String, options: SVNRequestOptions) async throws -> SVNWriteResult {
        SVNWriteResult(revision: 42)
    }
    func list(url: URL, options: SVNRequestOptions) async throws -> [SVNListEntry] {
        listCounts[url, default: 0] += 1
        if url.lastPathComponent == "root" { return StabilitySVNClient.entries }
        return try await withCheckedThrowingContinuation { pending[url] = $0 }
    }
    func waitForRequest(_ url: URL) async {
        while pending[url] == nil { await Task.yield() }
    }
    func resolve(_ url: URL, result: Result<[SVNListEntry], SVNClientError>) {
        guard let continuation = pending.removeValue(forKey: url) else { return }
        switch result {
        case .success(let entries): continuation.resume(returning: entries)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}

private actor StabilitySVNClient: SVNClient {
    static let entries = [
        SVNListEntry(name: "folder", kind: .directory, size: nil, revision: 4, author: nil, updatedAt: nil),
        SVNListEntry(name: "file.txt", kind: .file, size: 10, revision: 4, author: nil, updatedAt: nil)
    ]
    private var failLists = false
    private(set) var writeCount = 0
    private(set) var exportCount = 0
    private(set) var lastReplaceExpectedRevision: Int?
    private(set) var lastReplaceContents: String?
    func setFailLists(_ value: Bool) { failLists = value }
    func version() async throws -> String { "1.14.5" }
    func list(url: URL, options: SVNRequestOptions) async throws -> [SVNListEntry] {
        if failLists { throw SVNClientError.connectionTimedOut }
        if url.lastPathComponent == "folder" {
            return [SVNListEntry(name: "child.txt", kind: .file, size: 10, revision: 4, author: nil, updatedAt: nil)]
        }
        return Self.entries
    }
    private func commit() -> SVNWriteResult {
        writeCount += 1
        return SVNWriteResult(revision: 42)
    }
    func makeDirectory(url: URL, message: String, options: SVNRequestOptions) async throws -> SVNWriteResult { commit() }
    func move(from sourceURL: URL, to destinationURL: URL, message: String, options: SVNRequestOptions) async throws -> SVNWriteResult { commit() }
    func delete(urls: [URL], message: String, options: SVNRequestOptions) async throws -> SVNWriteResult { commit() }
    func upload(files: [URL], to directoryURL: URL, message: String, options: SVNRequestOptions) async throws -> SVNWriteResult { commit() }
    func replace(localFileURL: URL, targetURL: URL, expectedRevision: Int, message: String, options: SVNRequestOptions) async throws -> SVNWriteResult {
        lastReplaceExpectedRevision = expectedRevision
        lastReplaceContents = try String(contentsOf: localFileURL, encoding: .utf8)
        return commit()
    }
    func export(url: URL, to destinationURL: URL, revision: Int?, overwrite: Bool, options: SVNRequestOptions) async throws {
        exportCount += 1
        try Data("r\(revision ?? 0)".utf8).write(to: destinationURL)
    }
    func exportHistoricalVersion(url: URL, pegRevision: Int, revision: Int, to destinationURL: URL, overwrite: Bool, options: SVNRequestOptions) async throws {
        try await export(url: url, to: destinationURL, revision: revision, overwrite: overwrite, options: options)
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
        if url.path.hasSuffix("技术部") || url.path.hasSuffix("技术部/") {
            return [SVNListEntry(
                name: "API-Guide.txt", kind: .file, size: 20, revision: 8,
                author: "tester", updatedAt: Date(timeIntervalSince1970: 300)
            )]
        }
        return [
            SVNListEntry(name: "技术部", kind: .directory, size: nil, revision: 7, author: "tester", updatedAt: nil),
            SVNListEntry(name: "技术部/API-Guide.txt", kind: .file, size: 20, revision: 8, author: "tester", updatedAt: nil),
            SVNListEntry(name: "市场部", kind: .directory, size: nil, revision: 9, author: "tester", updatedAt: nil),
            SVNListEntry(name: "市场部/api-plan.txt", kind: .file, size: 30, revision: 9, author: "tester", updatedAt: nil),
            SVNListEntry(name: "README.txt", kind: .file, size: 10, revision: 5, author: "tester", updatedAt: nil)
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

private actor CoalescingSearchSVNClient: SVNClient {
    private(set) var recursiveListCount = 0
    private var recursiveContinuations: [CheckedContinuation<[SVNListEntry], Error>] = []

    func version() async throws -> String { "1.14.5" }

    func list(url: URL, options: SVNRequestOptions) async throws -> [SVNListEntry] {
        [SVNListEntry(name: "README.txt", kind: .file, size: 10, revision: 5, author: nil, updatedAt: nil)]
    }

    func listRecursively(url: URL, options: SVNRequestOptions) async throws -> [SVNListEntry] {
        recursiveListCount += 1
        return try await withCheckedThrowingContinuation { recursiveContinuations.append($0) }
    }

    func waitForRecursiveRequestCount(_ count: Int) async {
        while recursiveListCount < count { await Task.yield() }
    }

    func resolveRecursiveRequests() {
        let continuations = recursiveContinuations
        recursiveContinuations.removeAll()
        let entries = [
            SVNListEntry(name: "API-Guide.txt", kind: .file, size: 20, revision: 8, author: nil, updatedAt: nil),
            SVNListEntry(name: "README.txt", kind: .file, size: 10, revision: 5, author: nil, updatedAt: nil)
        ]
        continuations.forEach { $0.resume(returning: entries) }
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

private actor RetryDownloadSVNClient: SVNClient {
    private(set) var exportCount = 0

    func version() async throws -> String { "1.14.5" }

    func list(url: URL, options: SVNRequestOptions) async throws -> [SVNListEntry] {
        [SVNListEntry(name: "重试.txt", kind: .file, size: 8, revision: 3, author: nil, updatedAt: nil)]
    }

    func export(
        url: URL,
        to destinationURL: URL,
        revision: Int?,
        overwrite: Bool,
        options: SVNRequestOptions
    ) async throws {
        exportCount += 1
        if exportCount == 1 { throw SVNClientError.invalidListXML }
        try Data("已完成".utf8).write(to: destinationURL)
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

private actor BatchDeleteSVNClient: SVNClient {
    private(set) var deletedURLBatches: [[URL]] = []
    private(set) var deleteMessages: [String] = []

    func version() async throws -> String { "1.14.5" }

    func list(url: URL, options: SVNRequestOptions) async throws -> [SVNListEntry] {
        [
            SVNListEntry(name: "说明.txt", kind: .file, size: 10, revision: 17, author: nil, updatedAt: nil),
            SVNListEntry(name: "资料", kind: .directory, size: nil, revision: 16, author: nil, updatedAt: nil)
        ]
    }

    func delete(urls: [URL], message: String, options: SVNRequestOptions) async throws -> SVNWriteResult {
        deletedURLBatches.append(urls)
        deleteMessages.append(message)
        return SVNWriteResult(revision: 18)
    }
}

private actor BatchDownloadSVNClient: SVNClient {
    private(set) var exportedNames: [String] = []

    func version() async throws -> String { "1.14.5" }
    func list(url: URL, options: SVNRequestOptions) async throws -> [SVNListEntry] { [] }

    func export(
        url: URL,
        to destinationURL: URL,
        revision: Int?,
        overwrite: Bool,
        options: SVNRequestOptions
    ) async throws {
        exportedNames.append(url.lastPathComponent)
        if url.lastPathComponent == "失败.txt" {
            throw SVNClientError.invalidListXML
        }
        try Data("success".utf8).write(to: destinationURL)
    }
}

private actor TreeOperationsSVNClient: SVNClient {
    struct Move: Sendable {
        let sourceURL: URL
        let destinationURL: URL
    }

    private var listCounts: [String: Int] = [:]
    private(set) var lastMove: Move?
    private(set) var lastUploadDirectory: URL?
    private(set) var lastCreatedDirectoryURL: URL?

    func version() async throws -> String { "1.14.5" }

    func list(url: URL, options: SVNRequestOptions) async throws -> [SVNListEntry] {
        listCounts[url.absoluteString, default: 0] += 1
        if url.path.hasSuffix("资料") || url.path.hasSuffix("资料/") {
            return [SVNListEntry(
                name: "旧版.txt", kind: .file, size: 4, revision: 2,
                author: "tester", updatedAt: nil
            )]
        }
        return [SVNListEntry(
            name: "资料", kind: .directory, size: nil, revision: 1,
            author: "tester", updatedAt: nil
        )]
    }

    func listCount(for url: URL) -> Int {
        listCounts[url.absoluteString, default: 0]
    }

    func move(
        from sourceURL: URL,
        to destinationURL: URL,
        message: String,
        options: SVNRequestOptions
    ) async throws -> SVNWriteResult {
        lastMove = Move(sourceURL: sourceURL, destinationURL: destinationURL)
        return SVNWriteResult(revision: 3)
    }

    func upload(
        files: [URL],
        to directoryURL: URL,
        message: String,
        options: SVNRequestOptions
    ) async throws -> SVNWriteResult {
        lastUploadDirectory = directoryURL
        return SVNWriteResult(revision: 4)
    }

    func makeDirectory(url: URL, message: String, options: SVNRequestOptions) async throws -> SVNWriteResult {
        lastCreatedDirectoryURL = url
        return SVNWriteResult(revision: 5)
    }
}
