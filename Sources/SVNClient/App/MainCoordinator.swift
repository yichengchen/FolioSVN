import AppKit

@MainActor
final class MainCoordinator {
    private var mainWindowController: MainWindowController?
    private let svnClient: any SVNClient
    private let profileService: RepositoryProfileService
    private let metadataService: RepositoryMetadataService
    private weak var sidebarViewController: SidebarViewController?
    private weak var browserViewModel: BrowserViewModel?

    var activeTransferCount: Int {
        browserViewModel?.activeTransferCount ?? 0
    }

    init(
        svnClient: any SVNClient,
        profileService: RepositoryProfileService,
        metadataService: RepositoryMetadataService
    ) {
        self.svnClient = svnClient
        self.profileService = profileService
        self.metadataService = metadataService
    }

    convenience init() throws {
        let databaseURL = try RepositoryProfileStore.defaultDatabaseURL()
        let profileStore = try RepositoryProfileStore(databaseURL: databaseURL)
        let metadataStore = try RepositoryMetadataStore(databaseURL: databaseURL)
        let credentialStore = KeychainCredentialStore()
        self.init(
            svnClient: SVNCLIGateway(),
            profileService: RepositoryProfileService(
                profileStore: profileStore,
                credentialStore: credentialStore
            ),
            metadataService: RepositoryMetadataService(store: metadataStore)
        )
    }

    func start() {
        let sidebarViewController = SidebarViewController()
        let browserViewModel = BrowserViewModel(svnClient: svnClient, metadataService: metadataService)
        browserViewModel.onRepositoryChanged = { [weak sidebarViewController] profileID, url in
            sidebarViewController?.invalidateDirectory(profileID: profileID, url: url)
        }
        browserViewModel.onMetadataChanged = { [weak self] in
            Task { await self?.reloadMetadata() }
        }
        let browserViewController = BrowserViewController(viewModel: browserViewModel)
        let windowController = MainWindowController(
            sidebarViewController: sidebarViewController,
            browserViewController: browserViewController
        )
        windowController.onConnectRepository = { [weak self, weak browserViewModel] in
            guard let self, let browserViewModel else { return }
            self.presentRepositoryConnection(for: browserViewModel)
        }
        sidebarViewController.onSelectRepository = { [weak self] profileID in
            self?.connect(profileID: profileID)
        }
        sidebarViewController.onSelectDirectory = { [weak self] profileID, url in
            self?.connect(profileID: profileID, initialURL: url)
        }
        sidebarViewController.onLoadDirectories = { [weak self] profileID, url in
            guard let self,
                  let connection = try await profileService.connection(profileID: profileID) else { return [] }
            let entries: [SVNListEntry]
            if let snapshot = try? await metadataService.directoryCache(profileID: profileID, url: url) {
                entries = snapshot.entries
            } else {
                entries = try await svnClient.list(url: url, options: connection.requestOptions)
                try? await metadataService.replaceDirectoryCache(profileID: profileID, url: url, entries: entries)
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
        self.sidebarViewController = sidebarViewController
        self.browserViewModel = browserViewModel
        mainWindowController = windowController
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        Task { [weak self] in
            await self?.reloadRepositoryProfiles(presentEditorWhenEmpty: true)
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
        }
        connectionViewController.onSave = { [weak self, weak parentWindow, weak sheetWindow, weak browserViewModel] draft in
            guard let self, let browserViewModel else { return }
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
            _ = try await self.svnClient.list(url: profile.startURL, options: draft.requestOptions)
            try await self.profileService.save(profile: profile, password: draft.password)
            try await browserViewModel.connect(profile: profile, password: draft.password)
            await self.reloadRepositoryProfiles()
            guard let parentWindow, let sheetWindow else { return }
            parentWindow.endSheet(sheetWindow)
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
        Task { [weak self] in
            do {
                guard let self,
                      let connection = try await profileService.connection(profileID: profileID),
                      let browserViewModel else { return }
                try await browserViewModel.connect(
                    profile: connection.profile,
                    password: connection.password,
                    initialURL: initialURL
                )
            } catch {
                self?.presentError(title: "无法连接服务器", error: error)
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
        Task { [weak self] in
            do {
                guard let self,
                      let connection = try await profileService.connection(profileID: profileID),
                      let browserViewModel else { return }
                let info = try await svnClient.info(url: url, options: connection.requestOptions)
                if let favoriteID {
                    try await metadataService.setFavoriteAvailability(
                        id: favoriteID,
                        isAvailable: true,
                        revision: info.lastChangedRevision ?? revision
                    )
                }
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
                    guard NSWorkspace.shared.open(localURL) else {
                        throw SavedItemError.noApplication
                    }
                }
                await reloadMetadata()
            } catch {
                if let favoriteID, Self.isMissingItem(error) {
                    try? await self?.metadataService.setFavoriteAvailability(
                        id: favoriteID,
                        isAvailable: false,
                        revision: nil
                    )
                    await self?.reloadMetadata()
                }
                self?.presentError(title: "无法打开“\(name)”", error: error)
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
