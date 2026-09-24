import AppKit
import SnapKit

final class MainWindowController: NSWindowController {
    var onConnectRepository: (() -> Void)?
    private let browserViewController: BrowserViewController
    private let workingCopyViewController: WorkingCopyViewController?
    private let contentContainerController = MainContentViewController()
    private let searchField = NSSearchField()
    private var synchronizedSearchQuery = ""
    private enum ContentMode { case repository, workingCopy }
    private var contentMode = ContentMode.repository

    private enum ToolbarIdentifier {
        static let main = NSToolbar.Identifier("MainToolbarV16")
        static let connect = NSToolbarItem.Identifier("ConnectRepository")
        static let back = NSToolbarItem.Identifier("Back")
        static let forward = NSToolbarItem.Identifier("Forward")
        static let refresh = NSToolbarItem.Identifier("Refresh")
        static let newFolder = NSToolbarItem.Identifier("NewFolder")
        static let upload = NSToolbarItem.Identifier("Upload")
        static let checkout = NSToolbarItem.Identifier("CheckoutWorkingCopy")
        static let search = NSToolbarItem.Identifier("Search")
    }

    init(
        sidebarViewController: SidebarViewController,
        browserViewController: BrowserViewController,
        workingCopyViewController: WorkingCopyViewController? = nil
    ) {
        self.browserViewController = browserViewController
        self.workingCopyViewController = workingCopyViewController
        let splitViewController = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = 210
        sidebarItem.maximumThickness = 280
        splitViewController.addSplitViewItem(sidebarItem)
        contentContainerController.show(browserViewController)
        splitViewController.addSplitViewItem(NSSplitViewItem(viewController: contentContainerController))

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
        searchField.placeholderString = "搜索当前目录"
        searchField.target = self
        searchField.action = #selector(submitSearch)
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = true
        searchField.widthAnchor.constraint(equalToConstant: 230).isActive = true
        window.toolbar = makeToolbar()
        window.toolbarStyle = .unified
        browserViewController.onNavigationStateChange = { [weak self] in
            guard let self else { return }
            let query = browserViewController.currentSearchQuery
            if query != synchronizedSearchQuery {
                searchField.stringValue = query
                synchronizedSearchQuery = query
            }
            self.window?.toolbar?.validateVisibleItems()
        }
        workingCopyViewController?.onNavigationStateChange = { [weak self] in
            self?.window?.toolbar?.validateVisibleItems()
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
    @objc private func refreshRepository() {
        switch contentMode {
        case .repository: browserViewController.refreshRepository()
        case .workingCopy: workingCopyViewController?.refreshWorkingCopy()
        }
    }
    @objc private func createFolder() { browserViewController.createFolder() }
    @objc private func uploadFiles() { browserViewController.uploadFiles() }
    @objc private func checkoutWorkingCopy() { browserViewController.checkoutCurrentDirectory() }
    @objc private func connectRepository() { onConnectRepository?() }
    @objc private func submitSearch() { performSearch() }

    private func performSearch() {
        browserViewController.updateSearch(query: searchField.stringValue)
    }

    func showRepositoryBrowser() {
        guard contentMode != .repository else { return }
        contentMode = .repository
        contentContainerController.show(browserViewController)
        searchField.isEnabled = true
        window?.toolbar?.validateVisibleItems()
    }

    func showWorkingCopy() {
        guard let workingCopyViewController, contentMode != .workingCopy else { return }
        contentMode = .workingCopy
        contentContainerController.show(workingCopyViewController)
        searchField.isEnabled = false
        window?.toolbar?.validateVisibleItems()
    }
}

extension MainWindowController: NSToolbarItemValidation {
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case ToolbarIdentifier.back:
            return contentMode == .repository && browserViewController.canGoBack
        case ToolbarIdentifier.forward:
            return contentMode == .repository && browserViewController.canGoForward
        case ToolbarIdentifier.refresh:
            return contentMode == .repository
                ? browserViewController.hasRepositoryConnection && browserViewController.canModifyRepository
                : workingCopyViewController?.canRefresh == true
        case ToolbarIdentifier.newFolder, ToolbarIdentifier.upload:
            return contentMode == .repository && browserViewController.canModifyRepository
        case ToolbarIdentifier.checkout:
            return contentMode == .repository && browserViewController.canCheckoutCurrentDirectory
        case ToolbarIdentifier.search:
            return contentMode == .repository && browserViewController.hasRepositoryConnection
        default:
            return true
        }
    }
}

private final class MainContentViewController: NSViewController {
    private weak var currentViewController: NSViewController?

    override func loadView() {
        view = NSView()
    }

    func show(_ viewController: NSViewController) {
        guard currentViewController !== viewController else { return }
        currentViewController?.view.removeFromSuperview()
        currentViewController?.removeFromParent()
        addChild(viewController)
        view.addSubview(viewController.view)
        viewController.view.snp.makeConstraints { $0.edges.equalToSuperview() }
        currentViewController = viewController
    }
}

extension MainWindowController: NSToolbarDelegate {
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar, ToolbarIdentifier.connect,
            ToolbarIdentifier.back, ToolbarIdentifier.forward,
            ToolbarIdentifier.refresh, .flexibleSpace,
            ToolbarIdentifier.search,
            ToolbarIdentifier.checkout, ToolbarIdentifier.newFolder, ToolbarIdentifier.upload, .space
        ]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar, ToolbarIdentifier.connect,
            ToolbarIdentifier.back, ToolbarIdentifier.forward,
            ToolbarIdentifier.refresh, .flexibleSpace,
            ToolbarIdentifier.search,
            ToolbarIdentifier.checkout, ToolbarIdentifier.newFolder, ToolbarIdentifier.upload
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
                label: "刷新",
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
        case ToolbarIdentifier.checkout:
            return makeToolbarItem(
                identifier: itemIdentifier,
                label: "检出",
                symbolName: "externaldrive.badge.plus",
                action: #selector(checkoutWorkingCopy)
            )
        case ToolbarIdentifier.search:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "搜索"
            item.paletteLabel = "搜索文件名"
            item.view = searchField
            return item
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
