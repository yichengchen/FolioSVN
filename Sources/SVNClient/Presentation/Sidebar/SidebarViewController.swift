import AppKit
import SnapKit

final class SidebarViewController: NSViewController, NSMenuItemValidation, NSMenuDelegate {
    var onSelectRepository: ((UUID) -> Void)?
    var onSelectDirectory: ((UUID, URL) -> Void)?
    var onLoadDirectories: ((UUID, URL) async throws -> [(name: String, url: URL)])?
    var onAddRepository: (() -> Void)?
    var onEditRepository: ((UUID) -> Void)?
    var onDeleteRepository: ((UUID) -> Void)?
    var onSelectSavedItem: ((UUID, URL, String, SavedRepositoryItemKind, Int?, UUID?) -> Void)?
    var onRenameFavorite: ((UUID, String) -> Void)?
    var onRemoveFavorite: ((UUID) -> Void)?

    private let stateStore: SidebarStateStore
    private let scrollView = NSScrollView()
    private let outlineView = NSOutlineView()
    private let footerView = NSVisualEffectView()
    private let addRepositoryButton = NSButton()
    private var rootNodes = SidebarItem.roots(profiles: [])
    private var profiles: [RepositoryProfile] = []
    private var favorites: [FavoriteRepositoryItem] = []
    private var isRestoringState = false
    private var isSelectingContextMenuItem = false
    private var shouldActivateRestoredSelection = false
    private var directoryLoadTasks: [String: (id: UUID, task: Task<Void, Never>)] = [:]

    init(userDefaults: UserDefaults = .standard) {
        stateStore = SidebarStateStore(userDefaults: userDefaults)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let backgroundView = NSVisualEffectView()
        backgroundView.material = .sidebar
        backgroundView.blendingMode = .behindWindow
        backgroundView.state = .active
        view = backgroundView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "浏览"
        configureOutlineView()
        configureFooter()

        view.addSubview(scrollView)
        view.addSubview(footerView)
        scrollView.snp.makeConstraints {
            $0.top.leading.trailing.equalToSuperview()
            $0.bottom.equalTo(footerView.snp.top)
        }
        footerView.snp.makeConstraints {
            $0.leading.trailing.bottom.equalToSuperview()
            $0.height.equalTo(48)
        }
    }

    private func configureOutlineView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SidebarColumn"))
        column.title = "浏览"
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .custom
        outlineView.backgroundColor = .clear
        outlineView.indentationPerLevel = 14
        outlineView.floatsGroupRows = false
        outlineView.delegate = self
        outlineView.dataSource = self
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.contentInsets = NSEdgeInsets(top: 10, left: 8, bottom: 8, right: 8)

        let menu = NSMenu()
        menu.addItem(withTitle: "编辑服务器…", action: #selector(editRepository), keyEquivalent: "")
        menu.addItem(withTitle: "移除服务器", action: #selector(deleteRepository), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "重命名收藏…", action: #selector(renameFavorite), keyEquivalent: "")
        menu.addItem(withTitle: "从收藏移除", action: #selector(removeFavorite), keyEquivalent: "")
        for item in menu.items { item.target = self }
        menu.delegate = self
        outlineView.menu = menu
    }

    private func configureFooter() {
        footerView.material = .sidebar
        footerView.blendingMode = .withinWindow
        footerView.state = .active

        let divider = NSBox()
        divider.boxType = .separator
        addRepositoryButton.title = "添加服务器"
        addRepositoryButton.image = NSImage(
            systemSymbolName: "plus",
            accessibilityDescription: "添加服务器"
        )
        addRepositoryButton.imagePosition = .imageLeading
        addRepositoryButton.bezelStyle = .recessed
        addRepositoryButton.controlSize = .large
        addRepositoryButton.target = self
        addRepositoryButton.action = #selector(addRepository)

        footerView.addSubview(divider)
        footerView.addSubview(addRepositoryButton)
        divider.snp.makeConstraints {
            $0.top.leading.trailing.equalToSuperview()
            $0.height.equalTo(1)
        }
        addRepositoryButton.snp.makeConstraints {
            $0.leading.trailing.equalToSuperview().inset(10)
            $0.centerY.equalToSuperview().offset(1)
            $0.height.equalTo(30)
        }
    }

    @objc private func addRepository() {
        onAddRepository?()
    }

    @objc private func editRepository() {
        guard let profileID = selectedRepositoryID else { return }
        onEditRepository?(profileID)
    }

    @objc private func deleteRepository() {
        guard let profileID = selectedRepositoryID else { return }
        onDeleteRepository?(profileID)
    }

    @objc private func removeFavorite() {
        guard let item = selectedSidebarItem,
              case let .favorite(favorite) = item.kind else { return }
        onRemoveFavorite?(favorite.id)
    }

    @objc private func renameFavorite() {
        guard let item = selectedSidebarItem,
              case let .favorite(favorite) = item.kind else { return }
        let alert = NSAlert()
        alert.messageText = "重命名收藏"
        alert.informativeText = "只修改侧边栏中的显示名称，不会重命名 SVN 中的文件或文件夹。"
        alert.addButton(withTitle: "重命名")
        alert.addButton(withTitle: "取消")

        let field = NSTextField(string: favorite.name)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        DispatchQueue.main.async { [weak alert, weak field] in
            guard let alert, let field else { return }
            alert.window.makeFirstResponder(field)
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: field.stringValue.utf16.count)
        }

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != favorite.name else { return }
        onRenameFavorite?(favorite.id, name)
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === outlineView.menu,
              let event = NSApp.currentEvent,
              event.window === view.window else { return }
        let point = outlineView.convert(event.locationInWindow, from: nil)
        let clickedRow = outlineView.row(at: point)
        guard clickedRow >= 0 else { return }
        isSelectingContextMenuItem = true
        outlineView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        isSelectingContextMenuItem = false
    }

    private var selectedSidebarItem: SidebarItem? {
        guard outlineView.selectedRow >= 0 else { return nil }
        return outlineView.item(atRow: outlineView.selectedRow) as? SidebarItem
    }

    private var selectedRepositoryID: UUID? {
        guard outlineView.selectedRow >= 0,
              let item = outlineView.item(atRow: outlineView.selectedRow) as? SidebarItem else { return nil }
        return item.repositoryProfileID
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let item = selectedSidebarItem else { return false }
        switch menuItem.action {
        case #selector(editRepository), #selector(deleteRepository):
            if case .repository = item.kind { return true }
            return false
        case #selector(renameFavorite), #selector(removeFavorite):
            if case .favorite = item.kind { return true }
            return false
        default:
            return false
        }
    }

    func setRepositoryProfiles(_ profiles: [RepositoryProfile], activateRestoredSelection: Bool = false) {
        self.profiles = profiles
        shouldActivateRestoredSelection = activateRestoredSelection
        rebuildRoots()
    }

    func setMetadata(favorites: [FavoriteRepositoryItem]) {
        self.favorites = favorites
        guard let commonRoot = rootNodes.first(where: { $0.stateKey == "group.common" }),
              let favoritesRoot = commonRoot.children.first(where: { $0.stateKey == "favorites.root" }) else {
            rebuildRoots()
            return
        }
        let updatedCommonRoot = SidebarItem.roots(
            profiles: profiles,
            favorites: favorites
        )[0]
        favoritesRoot.children = updatedCommonRoot.children[0].children
        outlineView.reloadItem(favoritesRoot, reloadChildren: true)
        restoreOutlineState()
    }

    func clearSelection(profileID: UUID) {
        guard selectedSidebarItem?.repositoryProfileID == profileID else { return }
        outlineView.deselectAll(nil)
        stateStore.setSelected(key: nil)
    }

    private func rebuildRoots() {
        directoryLoadTasks.values.forEach { $0.task.cancel() }
        directoryLoadTasks.removeAll()
        rootNodes = SidebarItem.roots(profiles: profiles, favorites: favorites)
        outlineView.reloadData()
        restoreOutlineState()
    }

    func invalidateDirectory(profileID: UUID, url: URL) {
        cancelDirectoryLoad(profileID: profileID, url: url)
        guard let item = findItem(where: {
            $0.repositoryLocation?.profileID == profileID && $0.repositoryLocation?.url == url
        }) else { return }
        item.children = [SidebarItem.loadingPlaceholder()]
        item.hasLoadedChildren = false
        outlineView.reloadItem(item, reloadChildren: true)
        if stateStore.expandedKeys.contains(item.stateKey ?? "") {
            outlineView.expandItem(item)
            loadDirectoryChildren(for: item)
        }
    }

    func updateDirectory(profileID: UUID, url: URL, entries: [SVNListEntry]) {
        cancelDirectoryLoad(profileID: profileID, url: url)
        guard let item = findItem(where: {
            $0.repositoryLocation?.profileID == profileID && $0.repositoryLocation?.url == url
        }) else { return }
        applyDirectories(entries.filter { $0.kind == .directory }.map {
            (name: $0.name, url: url.appendingPathComponent($0.name, isDirectory: true))
        }, to: item, profileID: profileID)
    }

    private func applyDirectories(_ directories: [(name: String, url: URL)], to item: SidebarItem, profileID: UUID) {
        let oldChildren = item.children
        item.children = directories.isEmpty
            ? [SidebarItem("没有子文件夹", symbolName: "folder", kind: .emptyState)]
            : directories.map { directory in
                if let existing = oldChildren.first(where: { $0.repositoryLocation?.url == directory.url && $0.title == directory.name }) {
                    return existing
                }
                return SidebarItem(directory.name, symbolName: "folder",
                    children: [SidebarItem.loadingPlaceholder()], kind: .directory(profileID, directory.url), hasLoadedChildren: false)
            }
        item.hasLoadedChildren = true
        outlineView.reloadItem(item, reloadChildren: true)
        restoreOutlineState()
    }

    private func restoreOutlineState() {
        isRestoringState = true
        restoreExpansion(in: rootNodes)
        let restoredItem = restoreSelectionIfAvailable()
        isRestoringState = false
        if shouldActivateRestoredSelection, let restoredItem {
            shouldActivateRestoredSelection = false
            activate(restoredItem)
        }
    }

    private func restoreExpansion(in items: [SidebarItem]) {
        for item in items {
            if let key = item.stateKey, stateStore.expandedKeys.contains(key) {
                outlineView.expandItem(item)
            }
            if item.hasLoadedChildren {
                restoreExpansion(in: item.children)
            }
        }
    }

    private func restoreSelectionIfAvailable() -> SidebarItem? {
        guard let key = stateStore.selectedItemKey,
              let selected = findItem(where: { $0.stateKey == key }) else { return nil }
        let row = outlineView.row(forItem: selected)
        guard row >= 0 else { return nil }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return selected
    }

    private func findItem(where predicate: (SidebarItem) -> Bool) -> SidebarItem? {
        func search(_ items: [SidebarItem]) -> SidebarItem? {
            for item in items {
                if predicate(item) { return item }
                if let match = search(item.children) { return match }
            }
            return nil
        }
        return search(rootNodes)
    }
}

extension SidebarViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarItem)?.children.count ?? rootNodes.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? SidebarItem)?.children ?? rootNodes)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? SidebarItem)?.children.isEmpty ?? true)
    }
}

extension SidebarViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? SidebarItem)?.isGroup == true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let sidebarItem = item as? SidebarItem else { return false }
        switch sidebarItem.kind {
        case .repository, .directory, .favorite: return true
        default: return false
        }
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let sidebarItem = item as? SidebarItem else { return 32 }
        if sidebarItem.isGroup { return 28 }
        return sidebarItem.subtitle == nil ? 32 : 44
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard outlineView.selectedRow >= 0,
              let item = outlineView.item(atRow: outlineView.selectedRow) as? SidebarItem else { return }
        stateStore.setSelected(key: item.stateKey)
        if isRestoringState || isSelectingContextMenuItem { return }
        activate(item)
    }

    private func activate(_ item: SidebarItem) {
        switch item.kind {
        case .repository:
            if let location = item.repositoryLocation {
                onSelectRepository?(location.profileID)
            }
        case .directory:
            if let location = item.repositoryLocation {
                onSelectDirectory?(location.profileID, location.url)
            }
        case .favorite:
            if let saved = item.savedItem {
                onSelectSavedItem?(
                    saved.profileID,
                    saved.url,
                    saved.name,
                    saved.kind,
                    saved.revision,
                    saved.favoriteID
                )
            }
        default:
            break
        }
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? SidebarItem else { return }
        if isRestoringState && item.hasLoadedChildren { return }
        loadDirectoryChildren(for: item)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isRestoringState,
              let item = notification.userInfo?["NSObject"] as? SidebarItem,
              let key = item.stateKey else { return }
        stateStore.setExpanded(true, key: key)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isRestoringState,
              let item = notification.userInfo?["NSObject"] as? SidebarItem,
              let key = item.stateKey else { return }
        stateStore.setExpanded(false, key: key)
    }

    private func loadDirectoryChildren(for item: SidebarItem) {
        guard !item.isLoadingChildren,
              let location = item.repositoryLocation,
              let onLoadDirectories else { return }
        let key = directoryLoadKey(profileID: location.profileID, url: location.url)
        guard directoryLoadTasks[key] == nil else { return }
        let requestID = UUID()
        item.isLoadingChildren = true
        let task = Task { @MainActor [weak self, weak item] in
            guard let self, let item else { return }
            do {
                let directories = try await onLoadDirectories(location.profileID, location.url)
                try Task.checkCancellation()
                guard self.directoryLoadTasks[key]?.id == requestID,
                      self.findItem(where: { $0 === item }) != nil else { return }
                self.directoryLoadTasks.removeValue(forKey: key)
                item.isLoadingChildren = false
                self.applyDirectories(directories, to: item, profileID: location.profileID)
            } catch is CancellationError {
                guard self.directoryLoadTasks[key]?.id == requestID else { return }
                self.directoryLoadTasks.removeValue(forKey: key)
                item.isLoadingChildren = false
            } catch {
                guard self.directoryLoadTasks[key]?.id == requestID,
                      self.findItem(where: { $0 === item }) != nil else { return }
                self.directoryLoadTasks.removeValue(forKey: key)
                item.isLoadingChildren = false
                item.children = [SidebarItem("无法读取", subtitle: error.localizedDescription, symbolName: "exclamationmark.triangle", kind: .emptyState)]
                outlineView.reloadItem(item, reloadChildren: true)
                self.restoreOutlineState()
            }
        }
        directoryLoadTasks[key] = (requestID, task)
    }

    private func cancelDirectoryLoad(profileID: UUID, url: URL) {
        let key = directoryLoadKey(profileID: profileID, url: url)
        directoryLoadTasks.removeValue(forKey: key)?.task.cancel()
        findItem(where: {
            $0.repositoryLocation?.profileID == profileID && $0.repositoryLocation?.url == url
        })?.isLoadingChildren = false
    }

    private func directoryLoadKey(profileID: UUID, url: URL) -> String {
        profileID.uuidString + ":" + url.absoluteString
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let sidebarItem = item as? SidebarItem else { return nil }
        if sidebarItem.isGroup {
            let identifier = NSUserInterfaceItemIdentifier("SidebarGroupCell")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
                ?? makeGroupCell(identifier: identifier)
            cell.textField?.stringValue = sidebarItem.title
            return cell
        }

        let identifier = NSUserInterfaceItemIdentifier("SidebarCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarCellView
            ?? SidebarCellView(identifier: identifier)
        cell.configure(with: sidebarItem)
        return cell
    }

    private func makeGroupCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        let textField = NSTextField(labelWithString: "")

        cell.identifier = identifier
        cell.textField = textField
        cell.addSubview(textField)
        textField.font = .systemFont(ofSize: 11, weight: .semibold)
        textField.textColor = .secondaryLabelColor
        textField.snp.makeConstraints {
            $0.leading.trailing.equalToSuperview().inset(6)
            $0.bottom.equalToSuperview().inset(3)
        }
        return cell
    }
}

private final class SidebarCellView: NSTableCellView {
    private let symbolView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        symbolView.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        symbolView.contentTintColor = .secondaryLabelColor
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        subtitleLabel.font = .systemFont(ofSize: 10.5)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingMiddle

        addSubview(symbolView)
        addSubview(titleLabel)
        addSubview(subtitleLabel)
        imageView = symbolView
        textField = titleLabel

        symbolView.snp.makeConstraints {
            $0.leading.equalToSuperview().inset(6)
            $0.centerY.equalToSuperview()
            $0.width.height.equalTo(18)
        }
        titleLabel.snp.makeConstraints {
            $0.leading.equalTo(symbolView.snp.trailing).offset(7)
            $0.trailing.equalToSuperview().inset(6)
            $0.top.equalToSuperview().inset(5)
        }
        subtitleLabel.snp.makeConstraints {
            $0.leading.trailing.equalTo(titleLabel)
            $0.top.equalTo(titleLabel.snp.bottom).offset(1)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with item: SidebarItem) {
        titleLabel.stringValue = item.title
        subtitleLabel.stringValue = item.subtitle ?? ""
        subtitleLabel.isHidden = item.subtitle == nil
        titleLabel.textColor = item.repositoryProfileID == nil && item.subtitle != nil
            ? .secondaryLabelColor
            : .labelColor
        symbolView.image = NSImage(
            systemSymbolName: item.symbolName,
            accessibilityDescription: item.title
        )
        symbolView.contentTintColor = item.repositoryProfileID == nil
            ? .secondaryLabelColor
            : .controlAccentColor
    }
}
