import AppKit

final class MainWindowController: NSWindowController {
    var onConnectRepository: (() -> Void)?
    private let browserViewController: BrowserViewController
    private let searchField = NSSearchField()
    private let searchScopeControl = NSSegmentedControl(labels: ["当前目录", "配置范围"], trackingMode: .selectOne, target: nil, action: nil)

    private enum ToolbarIdentifier {
        static let main = NSToolbar.Identifier("MainToolbarV15")
        static let connect = NSToolbarItem.Identifier("ConnectRepository")
        static let back = NSToolbarItem.Identifier("Back")
        static let forward = NSToolbarItem.Identifier("Forward")
        static let refresh = NSToolbarItem.Identifier("Refresh")
        static let newFolder = NSToolbarItem.Identifier("NewFolder")
        static let upload = NSToolbarItem.Identifier("Upload")
        static let search = NSToolbarItem.Identifier("Search")
        static let searchScope = NSToolbarItem.Identifier("SearchScope")
        static let refreshIndex = NSToolbarItem.Identifier("RefreshSearchIndex")
    }

    init(sidebarViewController: SidebarViewController, browserViewController: BrowserViewController) {
        self.browserViewController = browserViewController
        let splitViewController = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = 210
        sidebarItem.maximumThickness = 280
        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(NSSplitViewItem(viewController: browserViewController))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppBrand.displayName
        window.minSize = NSSize(width: 800, height: 520)
        window.center()
        window.contentViewController = splitViewController
        splitViewController.splitView.setPosition(240, ofDividerAt: 0)

        super.init(window: window)
        searchField.placeholderString = "搜索文件名"
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.sendsSearchStringImmediately = true
        searchScopeControl.selectedSegment = 1
        searchScopeControl.target = self
        searchScopeControl.action = #selector(searchScopeChanged)
        searchField.widthAnchor.constraint(equalToConstant: 230).isActive = true
        window.toolbar = makeToolbar()
        window.toolbarStyle = .unified
        browserViewController.onNavigationStateChange = { [weak self] in
            guard let self else { return }
            if searchField.stringValue != browserViewController.currentSearchQuery {
                searchField.stringValue = browserViewController.currentSearchQuery
            }
            self.window?.toolbar?.validateVisibleItems()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: ToolbarIdentifier.main)
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        return toolbar
    }

    @objc private func navigateBack() { browserViewController.navigateBack() }
    @objc private func navigateForward() { browserViewController.navigateForward() }
    @objc private func refreshRepository() { browserViewController.refreshRepository() }
    @objc private func createFolder() { browserViewController.createFolder() }
    @objc private func uploadFiles() { browserViewController.uploadFiles() }
    @objc private func connectRepository() { onConnectRepository?() }
    @objc private func searchChanged() { performSearch() }
    @objc private func searchScopeChanged() { performSearch() }
    @objc private func refreshSearchIndex() { browserViewController.refreshSearchIndex() }

    private func performSearch() {
        let scope: BrowserViewModel.SearchScope = searchScopeControl.selectedSegment == 0
            ? .currentDirectory
            : .configuredRoot
        browserViewController.updateSearch(query: searchField.stringValue, scope: scope)
    }
}

extension MainWindowController: NSToolbarItemValidation {
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case ToolbarIdentifier.back:
            return browserViewController.canGoBack
        case ToolbarIdentifier.forward:
            return browserViewController.canGoForward
        case ToolbarIdentifier.refresh, ToolbarIdentifier.newFolder, ToolbarIdentifier.upload:
            return browserViewController.canModifyRepository
        case ToolbarIdentifier.search, ToolbarIdentifier.searchScope, ToolbarIdentifier.refreshIndex:
            return browserViewController.hasRepositoryConnection
        default:
            return true
        }
    }
}

extension MainWindowController: NSToolbarDelegate {
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar, ToolbarIdentifier.connect,
            ToolbarIdentifier.back, ToolbarIdentifier.forward,
            ToolbarIdentifier.refresh, .flexibleSpace,
            ToolbarIdentifier.search, ToolbarIdentifier.searchScope, ToolbarIdentifier.refreshIndex,
            ToolbarIdentifier.newFolder, ToolbarIdentifier.upload, .space
        ]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar, ToolbarIdentifier.connect,
            ToolbarIdentifier.back, ToolbarIdentifier.forward,
            ToolbarIdentifier.refresh, .flexibleSpace,
            ToolbarIdentifier.search, ToolbarIdentifier.searchScope, ToolbarIdentifier.refreshIndex,
            ToolbarIdentifier.newFolder, ToolbarIdentifier.upload
        ]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case ToolbarIdentifier.connect:
            return makeToolbarItem(
                identifier: itemIdentifier,
                label: "连接仓库",
                symbolName: "externaldrive.connected.to.line.below",
                action: #selector(connectRepository)
            )
        case ToolbarIdentifier.back:
            return makeToolbarItem(
                identifier: itemIdentifier,
                label: "后退",
                symbolName: "chevron.left",
                action: #selector(navigateBack)
            )
        case ToolbarIdentifier.forward:
            return makeToolbarItem(
                identifier: itemIdentifier,
                label: "前进",
                symbolName: "chevron.right",
                action: #selector(navigateForward)
            )
        case ToolbarIdentifier.refresh:
            return makeToolbarItem(
                identifier: itemIdentifier,
                label: "刷新缓存",
                symbolName: "arrow.clockwise",
                action: #selector(refreshRepository)
            )
        case ToolbarIdentifier.newFolder:
            return makeToolbarItem(
                identifier: itemIdentifier,
                label: "新建文件夹",
                symbolName: "folder.badge.plus",
                action: #selector(createFolder)
            )
        case ToolbarIdentifier.upload:
            return makeToolbarItem(
                identifier: itemIdentifier,
                label: "上传",
                symbolName: "square.and.arrow.up",
                action: #selector(uploadFiles)
            )
        case ToolbarIdentifier.search:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "搜索"
            item.paletteLabel = "搜索文件名"
            item.view = searchField
            return item
        case ToolbarIdentifier.searchScope:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "搜索范围"
            item.view = searchScopeControl
            return item
        case ToolbarIdentifier.refreshIndex:
            return makeToolbarItem(
                identifier: itemIdentifier,
                label: "更新索引",
                symbolName: "arrow.trianglehead.2.clockwise.rotate.90",
                action: #selector(refreshSearchIndex)
            )
        default:
            return nil
        }
    }

    private func makeToolbarItem(
        identifier: NSToolbarItem.Identifier,
        label: String,
        symbolName: String,
        action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)
        item.target = self
        item.action = action
        return item
    }
}
