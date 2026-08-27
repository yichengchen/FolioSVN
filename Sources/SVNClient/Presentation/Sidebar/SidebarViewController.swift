import AppKit
import SnapKit

final class SidebarViewController: NSViewController, NSMenuItemValidation {
    var onSelectRepository: ((UUID) -> Void)?
    var onSelectDirectory: ((UUID, URL) -> Void)?
    var onLoadDirectories: ((UUID, URL) async throws -> [(name: String, url: URL)])?
    var onAddRepository: (() -> Void)?
    var onEditRepository: ((UUID) -> Void)?
    var onDeleteRepository: ((UUID) -> Void)?
    var onSelectSavedItem: ((UUID, URL, String, SavedRepositoryItemKind, Int?, UUID?) -> Void)?
    var onRemoveFavorite: ((UUID) -> Void)?
    var onClearRecentItems: (() -> Void)?

    private let scrollView = NSScrollView()
    private let outlineView = NSOutlineView()
    private let footerView = NSVisualEffectView()
    private let addRepositoryButton = NSButton()
    private var rootNodes = SidebarItem.roots(profiles: [])
    private var profiles: [RepositoryProfile] = []
    private var favorites: [FavoriteRepositoryItem] = []
    private var recentItems: [RecentRepositoryItem] = []

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
        menu.addItem(withTitle: "从收藏移除", action: #selector(removeFavorite), keyEquivalent: "")
        menu.addItem(withTitle: "清空最近访问", action: #selector(clearRecentItems), keyEquivalent: "")
        for item in menu.items { item.target = self }
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

    @objc private func clearRecentItems() {
        guard let item = selectedSidebarItem else { return }
        switch item.kind {
        case .recentsRoot, .recent:
            onClearRecentItems?()
        default:
            break
        }
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
        case #selector(removeFavorite):
            if case .favorite = item.kind { return true }
            return false
        case #selector(clearRecentItems):
            switch item.kind {
            case .recentsRoot, .recent: return !recentItems.isEmpty
            default: return false
            }
        default:
            return false
        }
    }

    func setRepositoryProfiles(_ profiles: [RepositoryProfile]) {
        self.profiles = profiles
        rebuildRoots()
    }

    func setMetadata(favorites: [FavoriteRepositoryItem], recentItems: [RecentRepositoryItem]) {
        self.favorites = favorites
        self.recentItems = recentItems
        guard !rootNodes.isEmpty else {
            rebuildRoots()
            return
        }
        let commonRoot = SidebarItem.roots(
            profiles: profiles,
            favorites: favorites,
            recentItems: recentItems
        )[0]
        rootNodes[0] = commonRoot
        outlineView.reloadData()
        outlineView.expandItem(commonRoot)
        commonRoot.children.forEach { outlineView.expandItem($0) }
    }

    private func rebuildRoots() {
        rootNodes = SidebarItem.roots(profiles: profiles, favorites: favorites, recentItems: recentItems)
        outlineView.reloadData()
        for rootNode in rootNodes {
            outlineView.expandItem(rootNode)
        }
        if let commonGroup = rootNodes.first(where: { $0.title == "常用" }) {
            commonGroup.children.forEach { outlineView.expandItem($0) }
        }
        if profiles.count == 1,
           let serverGroup = rootNodes.first(where: { $0.title == "SVN 服务器" }),
           let repository = serverGroup.children.first {
            outlineView.expandItem(repository)
        }
    }

    func invalidateDirectories(profileID: UUID) {
        guard let serverGroup = rootNodes.first(where: { $0.title == "SVN 服务器" }),
              let repository = serverGroup.children.first(where: { $0.repositoryProfileID == profileID }) else { return }
        repository.children = [SidebarItem.loadingPlaceholder()]
        repository.hasLoadedChildren = false
        outlineView.reloadItem(repository, reloadChildren: true)
        if outlineView.isItemExpanded(repository) {
            loadDirectoryChildren(for: repository)
        }
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
        case .repository, .directory, .favorite, .recent, .recentsRoot: return true
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
        switch item.kind {
        case .repository:
            if let location = item.repositoryLocation {
                onSelectRepository?(location.profileID)
            }
        case .directory:
            if let location = item.repositoryLocation {
                onSelectDirectory?(location.profileID, location.url)
            }
        case .favorite, .recent:
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
        case .recentsRoot:
            break
        default:
            break
        }
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? SidebarItem else { return }
        loadDirectoryChildren(for: item)
    }

    private func loadDirectoryChildren(for item: SidebarItem) {
        guard !item.hasLoadedChildren,
              !item.isLoadingChildren,
              let location = item.repositoryLocation,
              let onLoadDirectories else { return }
        item.isLoadingChildren = true
        Task { @MainActor [weak self, weak item] in
            guard let self, let item else { return }
            do {
                let directories = try await onLoadDirectories(location.profileID, location.url)
                item.children = directories.isEmpty
                    ? [SidebarItem("没有子文件夹", symbolName: "folder", kind: .emptyState)]
                    : directories.map { directory in
                        SidebarItem(
                            directory.name,
                            symbolName: "folder",
                            children: [SidebarItem.loadingPlaceholder()],
                            kind: .directory(location.profileID, directory.url),
                            hasLoadedChildren: false
                        )
                    }
                item.hasLoadedChildren = true
            } catch {
                item.children = [SidebarItem("无法读取", subtitle: error.localizedDescription, symbolName: "exclamationmark.triangle", kind: .emptyState)]
            }
            item.isLoadingChildren = false
            outlineView.reloadItem(item, reloadChildren: true)
            outlineView.expandItem(item)
        }
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
