import AppKit

@MainActor
final class MainCoordinator {
    private var mainWindowController: MainWindowController?
    private let svnClient: any SVNClient
    private let profileService: RepositoryProfileService
    private let metadataService: RepositoryMetadataService
    private let workingCopyService: WorkingCopyService
    private weak var sidebarViewController: SidebarViewController?
    private weak var browserViewController: BrowserViewController?
    private weak var browserViewModel: BrowserViewModel?
    private weak var workingCopyViewController: WorkingCopyViewController?
    private var connectionTask: Task<Void, Never>?
    private var workingCopyOpenTask: Task<Void, Never>?
    private var checkoutTask: Task<Void, Never>?
    private var connectionRequestID = UUID()
    private var workingCopyOpenRequestID = UUID()

    var activeTransferCount: Int {
        (browserViewModel?.activeTransferCount ?? 0) + (checkoutTask == nil ? 0 : 1)
    }

    var modifiedOpenDocumentCount: Int {
        browserViewModel?.modifiedOpenDocuments.count ?? 0
    }

    init(
        svnClient: any SVNClient,
        profileService: RepositoryProfileService,
        metadataService: RepositoryMetadataService,
        workingCopyService: WorkingCopyService
    ) {
        self.svnClient = svnClient
        self.profileService = profileService
        self.metadataService = metadataService
        self.workingCopyService = workingCopyService
    }

    convenience init() throws {
        let databaseURL = try RepositoryProfileStore.defaultDatabaseURL()
        let profileStore = try RepositoryProfileStore(databaseURL: databaseURL)
        let metadataStore = try RepositoryMetadataStore(databaseURL: databaseURL)
        let workingCopyStore = try WorkingCopyStore(databaseURL: databaseURL)
        let credentialStore = KeychainCredentialStore()
        let svnClient = SVNCLIGateway()
        let profileService = RepositoryProfileService(
            profileStore: profileStore,
            credentialStore: credentialStore
        )
        self.init(
            svnClient: svnClient,
            profileService: profileService,
            metadataService: RepositoryMetadataService(store: metadataStore),
            workingCopyService: WorkingCopyService(
                store: workingCopyStore,
                profileService: profileService,
                svnClient: svnClient
            )
        )
    }

    func start() {
        let sidebarViewController = SidebarViewController()
        let browserViewModel = BrowserViewModel(svnClient: svnClient, metadataService: metadataService)
        browserViewModel.onRepositoryChanged = { [weak sidebarViewController] profileID, url in
            sidebarViewController?.invalidateDirectory(profileID: profileID, url: url)
        }
        browserViewModel.onDirectoryCacheRefreshed = { [weak sidebarViewController] profileID, url, snapshot in
            sidebarViewController?.updateDirectory(profileID: profileID, url: url, entries: snapshot.entries)
        }
        browserViewModel.onMetadataChanged = { [weak self] in
            Task { await self?.reloadMetadata() }
        }
        let browserViewController = BrowserViewController(viewModel: browserViewModel)
        let workingCopyViewModel = WorkingCopyViewModel(service: workingCopyService)
        let workingCopyViewController = WorkingCopyViewController(viewModel: workingCopyViewModel)
        workingCopyViewController.onOpenRepositoryLocation = { [weak self] profileID, url in
            self?.connect(profileID: profileID, initialURL: url)
        }
        browserViewController.onCancelConnection = { [weak self] in self?.connectionTask?.cancel() }
        browserViewController.onCheckoutRequested = { [weak self] profileID, url, name in
            self?.presentCheckout(profileID: profileID, repositoryURL: url, suggestedName: name)
        }
        let windowController = MainWindowController(
            sidebarViewController: sidebarViewController,
            browserViewController: browserViewController,
            workingCopyViewController: workingCopyViewController
        )
        windowController.onConnectRepository = { [weak self, weak browserViewModel] in
            guard let self, let browserViewModel else { return }
            self.presentRepositoryConnection(for: browserViewModel)
        }
        sidebarViewController.onSelectRepository = { [weak self] profileID in
            self?.mainWindowController?.showRepositoryBrowser()
            self?.connect(profileID: profileID)
        }
        sidebarViewController.onSelectDirectory = { [weak self] profileID, url in
            self?.mainWindowController?.showRepositoryBrowser()
            self?.connect(profileID: profileID, initialURL: url)
        }
        sidebarViewController.onLoadDirectories = { [weak self, weak sidebarViewController] profileID, url in
            guard let self,
                  let connection = try await profileService.connection(profileID: profileID) else { return [] }
            let entries: [SVNListEntry]
            if let snapshot = try? await metadataService.directoryCache(profileID: profileID, url: url) {
                entries = snapshot.entries
                if snapshot.isExpired() {
                    let metadataService = metadataService
                    let svnClient = svnClient
                    Task { @MainActor [weak sidebarViewController] in
                        do {
                            let updated = try await metadataService.refreshDirectoryCache(profileID: profileID, url: url) {
                                try await svnClient.list(url: url, options: connection.requestOptions)
                            }
                            guard try await metadataService.directoryCache(profileID: profileID, url: url) == updated else { return }
                            sidebarViewController?.updateDirectory(profileID: profileID, url: url, entries: updated.entries)
                        } catch {
                            // Keep usable cached directories when background revalidation fails.
                        }
                    }
                }
            } else {
                let snapshot = try await metadataService.refreshDirectoryCache(profileID: profileID, url: url) {
                    try await self.svnClient.list(url: url, options: connection.requestOptions)
                }
                entries = snapshot.entries
            }
            return entries
                .filter { $0.kind == .directory }
                .map { entry in
                    (
                        name: entry.name,
                        url: url.appendingPathComponent(entry.name, isDirectory: true)
                    )
                }
        }
        sidebarViewController.onAddRepository = { [weak self, weak browserViewModel] in
            guard let self, let browserViewModel else { return }
            self.presentRepositoryConnection(for: browserViewModel)
        }
        sidebarViewController.onEditRepository = { [weak self] profileID in
            self?.edit(profileID: profileID)
        }
        sidebarViewController.onDeleteRepository = { [weak self] profileID in
            self?.confirmDelete(profileID: profileID)
        }
        sidebarViewController.onSelectSavedItem = { [weak self] profileID, url, name, kind, revision, favoriteID in
            self?.openSavedItem(
                profileID: profileID,
                url: url,
                name: name,
                kind: kind,
                revision: revision,
                favoriteID: favoriteID
            )
        }
        sidebarViewController.onRemoveFavorite = { [weak self, weak browserViewModel] favoriteID in
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await metadataService.removeFavorite(id: favoriteID)
                    try? await browserViewModel?.reloadFavorites()
                    await reloadMetadata()
                } catch {
                    presentError(title: "无法移除收藏", error: error)
                }
            }
        }
        sidebarViewController.onRenameFavorite = { [weak self] favoriteID, name in
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await metadataService.renameFavorite(id: favoriteID, name: name)
                    await reloadMetadata()
                } catch {
                    presentError(title: "无法重命名收藏", error: error)
                }
            }
        }
        sidebarViewController.onSelectWorkingCopy = { [weak self] id in
            self?.openWorkingCopy(id: id)
        }
        sidebarViewController.onRevealWorkingCopy = { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        sidebarViewController.onRemoveWorkingCopy = { [weak self] id in
            self?.confirmRemoveWorkingCopy(id: id)
        }
        sidebarViewController.onRelocateWorkingCopy = { [weak self] id in
            self?.presentWorkingCopyRelocation(id: id)
        }
        sidebarViewController.onRenameWorkingCopy = { [weak self] id, name in
            Task { [weak self] in
                guard let self else { return }
                do {
                    let updated = try await workingCopyService.rename(id: id, displayName: name)
                    await reloadWorkingCopies()
                    if self.workingCopyViewController?.workingCopyID == id {
                        self.workingCopyViewController?.open(updated)
                    }
                } catch {
                    presentError(title: "无法重命名工作副本", error: error)
                }
            }
        }
        self.sidebarViewController = sidebarViewController
        self.browserViewController = browserViewController
        self.browserViewModel = browserViewModel
        self.workingCopyViewController = workingCopyViewController
        mainWindowController = windowController
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        Task { [weak self] in
            await self?.reloadRepositoryProfiles(presentEditorWhenEmpty: true)
            await self?.reloadWorkingCopies()
        }
    }

    private func presentRepositoryConnection(
        for browserViewModel: BrowserViewModel,
        existingConnection: RepositoryConnection? = nil
    ) {
        guard let parentWindow = mainWindowController?.window else { return }

        let connectionViewController = RepositoryConnectionViewController(
            profile: existingConnection?.profile,
            password: existingConnection?.password
        )
        let sheetWindow = NSWindow(contentViewController: connectionViewController)
        sheetWindow.title = "连接 SVN 仓库"
        sheetWindow.styleMask = [.titled]

        connectionViewController.onCancel = { [weak parentWindow, weak sheetWindow] in
            guard let parentWindow, let sheetWindow else { return }
            parentWindow.endSheet(sheetWindow)
        }
        connectionViewController.onTest = { [weak self] draft in
            guard let self else { return }
            _ = try await self.svnClient.list(url: draft.startURL, options: draft.requestOptions)
            try Task.checkCancellation()
        }
        connectionViewController.onSave = { [weak self, weak parentWindow, weak sheetWindow, weak browserViewModel, weak connectionViewController] draft in
            guard let self, let browserViewModel else { return }
            connectionRequestID = UUID()
            connectionTask?.cancel()
            let now = Date()
            let profile = RepositoryProfile(
                id: existingConnection?.profile.id ?? UUID(),
                displayName: draft.displayName,
                baseURL: draft.url,
                username: draft.username,
                certificatePolicy: draft.certificatePolicy,
                startPath: draft.startPath,
                createdAt: existingConnection?.profile.createdAt ?? now,
                updatedAt: now
            )
            let entries = try await self.svnClient.list(url: profile.startURL, options: draft.requestOptions)
            try Task.checkCancellation()
            connectionViewController?.beginFinalizingSave()
            // The profile ID survives edits, but its credentials and visible tree may not.
            // Reconnecting must never reuse directory or search data read by the old account.
            try await self.metadataService.clearRepositoryCache(profileID: profile.id)
            try await self.profileService.save(profile: profile, password: draft.password)
            try await browserViewModel.connect(
                profile: profile,
                password: draft.password,
                prefetchedEntries: entries
            )
            self.mainWindowController?.showRepositoryBrowser()
            await self.reloadRepositoryProfiles()
            guard let parentWindow, let sheetWindow else { return }
            parentWindow.endSheet(sheetWindow)
            self.browserViewController?.reviewModifiedOpenDocumentsIfNeeded()
        }

        parentWindow.beginSheet(sheetWindow)
    }

    private func edit(profileID: UUID) {
        Task { [weak self] in
            do {
                guard let self,
                      let browserViewModel,
                      let connection = try await profileService.connection(profileID: profileID) else { return }
                presentRepositoryConnection(for: browserViewModel, existingConnection: connection)
            } catch {
                self?.presentError(title: "无法读取服务器配置", error: error)
            }
        }
    }

    private func confirmDelete(profileID: UUID) {
        Task { [weak self] in
            do {
                guard let self,
                      let connection = try await profileService.connection(profileID: profileID) else { return }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "移除“\(connection.profile.displayName)”？"
                alert.informativeText = "服务器配置和保存在本机 Keychain 中的密码将被移除，不会删除 SVN 仓库中的任何内容。"
                alert.addButton(withTitle: "移除")
                alert.addButton(withTitle: "取消")
                alert.buttons.first?.hasDestructiveAction = true
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                connectionRequestID = UUID()
                connectionTask?.cancel()
                try await profileService.delete(profileID: profileID)
                try await metadataService.deleteMetadata(profileID: profileID)
                browserViewModel?.disconnect(profileID: profileID)
                await reloadRepositoryProfiles()
            } catch {
                self?.presentError(title: "无法移除服务器", error: error)
            }
        }
    }

    private func reloadRepositoryProfiles(presentEditorWhenEmpty: Bool = false) async {
        do {
            let profiles = try await profileService.list()
            sidebarViewController?.setRepositoryProfiles(
                profiles,
                activateRestoredSelection: browserViewModel?.currentURL == nil
            )
            await reloadMetadata()
            if presentEditorWhenEmpty,
               profiles.isEmpty,
               mainWindowController?.window?.attachedSheet == nil,
               let browserViewModel {
                presentRepositoryConnection(for: browserViewModel)
            }
        } catch {
            presentError(title: "无法读取服务器配置", error: error)
        }
    }

    private func connect(profileID: UUID, initialURL: URL? = nil) {
        cancelPendingWorkingCopyOpen()
        mainWindowController?.showRepositoryBrowser()
        connectionTask?.cancel()
        let requestID = UUID()
        connectionRequestID = requestID
        connectionTask = Task { [weak self] in
            guard let self else { return }
            defer { if requestID == connectionRequestID { connectionTask = nil } }
            do {
                guard let browserViewModel else { return }
                guard let connection = try await profileService.connection(profileID: profileID) else {
                    guard requestID == connectionRequestID else { return }
                    sidebarViewController?.clearSelection(profileID: profileID)
                    return
                }
                try Task.checkCancellation()
                guard requestID == connectionRequestID else { return }
                try await browserViewModel.connect(
                    profile: connection.profile,
                    password: connection.password,
                    initialURL: initialURL
                )
                browserViewController?.reviewModifiedOpenDocumentsIfNeeded()
            } catch is CancellationError {
                // A newer sidebar selection or the cancellation button superseded this connection.
                guard requestID == connectionRequestID else { return }
                sidebarViewController?.clearSelection(profileID: profileID)
            } catch {
                guard requestID == connectionRequestID else { return }
                sidebarViewController?.clearSelection(profileID: profileID)
                presentError(title: "无法连接服务器", error: error)
            }
        }
    }

    private func openSavedItem(
        profileID: UUID,
        url: URL,
        name: String,
        kind: SavedRepositoryItemKind,
        revision: Int?,
        favoriteID: UUID?
    ) {
        cancelPendingWorkingCopyOpen()
        mainWindowController?.showRepositoryBrowser()
        connectionTask?.cancel()
        let requestID = UUID()
        connectionRequestID = requestID
        connectionTask = Task { [weak self] in
            guard let self else { return }
            defer { if requestID == connectionRequestID { connectionTask = nil } }
            do {
                guard let connection = try await profileService.connection(profileID: profileID),
                      let browserViewModel else { return }
                try Task.checkCancellation()
                guard requestID == connectionRequestID else { return }
                let info = try await svnClient.info(url: url, options: connection.requestOptions)
                try Task.checkCancellation()
                guard requestID == connectionRequestID else { return }
                if let favoriteID {
                    try await metadataService.setFavoriteAvailability(
                        id: favoriteID,
                        isAvailable: true,
                        revision: info.lastChangedRevision ?? revision
                    )
                }
                try Task.checkCancellation()
                guard requestID == connectionRequestID else { return }
                if kind == .directory {
                    try await browserViewModel.connect(
                        profile: connection.profile,
                        password: connection.password,
                        initialURL: url
                    )
                } else {
                    try await browserViewModel.connect(
                        profile: connection.profile,
                        password: connection.password,
                        initialURL: url.deletingLastPathComponent()
                    )
                    guard let row = browserViewModel.rows.first(where: { $0.url == url }) else {
                        throw SavedItemError.notFound
                    }
                    let localURL = try await browserViewModel.localURLForOpening(row)
                    try Task.checkCancellation()
                    guard requestID == connectionRequestID else { return }
                    guard NSWorkspace.shared.open(localURL) else {
                        throw SavedItemError.noApplication
                    }
                }
                browserViewController?.reviewModifiedOpenDocumentsIfNeeded()
                await reloadMetadata()
            } catch is CancellationError {
                // Superseded selections must not open a file or update the active browser.
            } catch {
                guard requestID == connectionRequestID else { return }
                if let favoriteID, Self.isMissingItem(error) {
                    try? await metadataService.setFavoriteAvailability(
                        id: favoriteID,
                        isAvailable: false,
                        revision: nil
                    )
                    await reloadMetadata()
                }
                guard requestID == connectionRequestID, !Task.isCancelled else { return }
                presentError(title: "无法打开“\(name)”", error: error)
            }
        }
    }

    private func reloadMetadata() async {
        do {
            let loadedFavorites = try await metadataService.favorites()
            sidebarViewController?.setMetadata(favorites: loadedFavorites)
        } catch {
            presentError(title: "无法读取收藏", error: error)
        }
    }

    private func reloadWorkingCopies() async {
        do {
            let workingCopies = try await workingCopyService.list()
            var items: [(WorkingCopy, WorkingCopyAvailability)] = []
            for workingCopy in workingCopies {
                items.append((workingCopy, await workingCopyService.availability(of: workingCopy)))
            }
            sidebarViewController?.setWorkingCopies(items)
        } catch {
            presentError(title: "无法读取工作副本", error: error)
        }
    }

    private func openWorkingCopy(id: UUID) {
        connectionRequestID = UUID()
        connectionTask?.cancel()
        connectionTask = nil
        workingCopyOpenTask?.cancel()
        let requestID = UUID()
        workingCopyOpenRequestID = requestID
        workingCopyOpenTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if requestID == workingCopyOpenRequestID {
                    workingCopyOpenTask = nil
                }
            }
            do {
                guard let workingCopy = try await workingCopyService.workingCopy(id: id) else { return }
                try Task.checkCancellation()
                guard requestID == workingCopyOpenRequestID else { return }
                mainWindowController?.showWorkingCopy()
                workingCopyViewController?.open(workingCopy)
            } catch is CancellationError {
                // A newer sidebar selection superseded this working copy.
            } catch {
                guard requestID == workingCopyOpenRequestID else { return }
                presentError(title: "无法打开工作副本", error: error)
            }
        }
    }

    private func cancelPendingWorkingCopyOpen() {
        workingCopyOpenRequestID = UUID()
        workingCopyOpenTask?.cancel()
        workingCopyOpenTask = nil
    }

    private func confirmRemoveWorkingCopy(id: UUID) {
        Task { [weak self] in
            do {
                guard let self,
                      let workingCopy = try await workingCopyService.workingCopy(id: id) else { return }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "移除“\(workingCopy.displayName)”？"
                alert.informativeText = "只会从 Folio SVN 侧边栏移除记录，本地文件夹和其中的文件不会被删除。"
                alert.addButton(withTitle: "移除记录")
                alert.addButton(withTitle: "取消")
                alert.buttons.first?.hasDestructiveAction = true
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                try await workingCopyService.remove(id: id)
                sidebarViewController?.clearWorkingCopySelection(id: id)
                if workingCopyViewController?.workingCopyID == id {
                    workingCopyViewController?.close()
                    mainWindowController?.showRepositoryBrowser()
                }
                await reloadWorkingCopies()
            } catch {
                self?.presentError(title: "无法移除工作副本", error: error)
            }
        }
    }

    private func presentWorkingCopyRelocation(id: UUID) {
        guard let parentWindow = mainWindowController?.window else { return }
        let panel = NSOpenPanel()
        panel.title = "重新定位工作副本"
        panel.message = "请选择原工作副本移动后的文件夹。应用会验证它仍然指向同一个 SVN 位置。"
        panel.prompt = "选择"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: parentWindow) { [weak self] response in
            guard response == .OK, let self, let localURL = panel.url else { return }
            Task { [weak self] in
                do {
                    guard let self else { return }
                    let updated = try await workingCopyService.relocate(id: id, to: localURL)
                    await reloadWorkingCopies()
                    sidebarViewController?.selectWorkingCopy(id: updated.id)
                    mainWindowController?.showWorkingCopy()
                    workingCopyViewController?.open(updated)
                } catch {
                    self?.presentError(title: "无法重新定位工作副本", error: error)
                }
            }
        }
    }

    private func presentCheckout(profileID: UUID, repositoryURL: URL, suggestedName: String) {
        guard checkoutTask == nil, let parentWindow = mainWindowController?.window else {
            NSSound.beep()
            return
        }
        let panel = NSOpenPanel()
        panel.title = "选择工作副本的保存位置"
        panel.prompt = "选择父文件夹"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: parentWindow) { [weak self, weak parentWindow] response in
            guard response == .OK, let self, let parentWindow, let parentURL = panel.url else { return }
            self.promptForWorkingCopyName(
                profileID: profileID,
                repositoryURL: repositoryURL,
                parentURL: parentURL,
                suggestedName: suggestedName,
                parentWindow: parentWindow
            )
        }
    }

    private func promptForWorkingCopyName(
        profileID: UUID,
        repositoryURL: URL,
        parentURL: URL,
        suggestedName: String,
        parentWindow: NSWindow
    ) {
        let alert = NSAlert()
        alert.messageText = "创建工作副本"
        alert.informativeText = "输入本地文件夹名称。首个版本会完整检出，并忽略 externals。"
        alert.addButton(withTitle: "开始检出")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(string: suggestedName.removingPercentEncoding ?? suggestedName)
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        alert.accessoryView = field
        alert.beginSheetModal(for: parentWindow) { [weak self, weak parentWindow] response in
            guard response == .alertFirstButtonReturn, let self, let parentWindow else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
                self.presentError(title: "工作副本名称无效", error: CheckoutInputError.invalidName)
                return
            }
            self.beginCheckout(
                profileID: profileID,
                repositoryURL: repositoryURL,
                destinationURL: parentURL.appendingPathComponent(name, isDirectory: true),
                displayName: name,
                parentWindow: parentWindow
            )
        }
    }

    private func beginCheckout(
        profileID: UUID,
        repositoryURL: URL,
        destinationURL: URL,
        displayName: String,
        parentWindow: NSWindow
    ) {
        let progressViewController = CheckoutProgressViewController(name: displayName, destinationURL: destinationURL)
        let progressWindow = NSWindow(contentViewController: progressViewController)
        progressWindow.title = "检出工作副本"
        progressWindow.styleMask = [.titled]
        progressViewController.onCancel = { [weak self] in self?.checkoutTask?.cancel() }
        parentWindow.beginSheet(progressWindow)

        checkoutTask = Task { @MainActor [weak self, weak parentWindow, weak progressWindow] in
            guard let self else { return }
            defer {
                checkoutTask = nil
                if let parentWindow, let progressWindow, parentWindow.attachedSheet === progressWindow {
                    parentWindow.endSheet(progressWindow)
                }
            }
            do {
                let workingCopy = try await workingCopyService.checkout(
                    profileID: profileID,
                    repositoryURL: repositoryURL,
                    destinationURL: destinationURL,
                    displayName: displayName
                )
                if let parentWindow, let progressWindow, parentWindow.attachedSheet === progressWindow {
                    parentWindow.endSheet(progressWindow)
                }
                await reloadWorkingCopies()
                sidebarViewController?.selectWorkingCopy(id: workingCopy.id)
                mainWindowController?.showWorkingCopy()
                workingCopyViewController?.open(workingCopy)
            } catch is CancellationError {
                return
            } catch {
                if let parentWindow, let progressWindow, parentWindow.attachedSheet === progressWindow {
                    parentWindow.endSheet(progressWindow)
                }
                presentError(title: "无法检出工作副本", error: error)
            }
        }
    }

    private static func isMissingItem(_ error: Error) -> Bool {
        guard case let SVNClientError.commandFailed(failure) = error else {
            guard let savedItemError = error as? SavedItemError else { return false }
            if case .notFound = savedItemError { return true }
            return false
        }
        return failure.standardError.contains("E160013") || failure.standardError.contains("E200009")
    }

    private func presentError(title: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        if let window = mainWindowController?.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    func reviewModifiedOpenDocumentsIfNeeded() {
        browserViewController?.reviewModifiedOpenDocumentsIfNeeded()
        workingCopyViewController?.refreshWhenApplicationBecomesActive()
    }

    func revealModifiedOpenDocumentCopies() {
        guard let urls = browserViewModel?.modifiedOpenDocuments.map(\.localURL), !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

private enum SavedItemError: LocalizedError {
    case notFound
    case noApplication

    var errorDescription: String? {
        switch self {
        case .notFound: "目标已经不存在"
        case .noApplication: "找不到可以打开该文件格式的应用"
        }
    }
}

private enum CheckoutInputError: LocalizedError {
    case invalidName

    var errorDescription: String? {
        "名称不能为空，也不能包含斜杠或使用 .、.."
    }
}
