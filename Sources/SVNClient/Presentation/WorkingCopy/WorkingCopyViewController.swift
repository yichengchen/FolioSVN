import AppKit
import SnapKit

@MainActor
final class WorkingCopyViewController: NSViewController, NSMenuItemValidation, NSMenuDelegate {
    var onNavigationStateChange: (() -> Void)?
    var onOpenRepositoryLocation: ((UUID, URL) -> Void)?

    private let viewModel: WorkingCopyViewModel
    private let pathLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let outlineView = NSOutlineView()
    private let emptyStateLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let cancelRefreshButton = NSButton(title: "取消", target: nil, action: nil)
    private let revealRootButton = NSButton()
    private let repositoryButton = NSButton()
    private var rootNodes: [WorkingCopyTreeNode] = []
    private var refreshTask: Task<Void, Never>?
    private var expandedPaths = Set<String>()
    private var selectedPaths = Set<String>()
    private var isRestoringState = false
    private var renderedWorkingCopyID: UUID?

    init(viewModel: WorkingCopyViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureOutlineView()
        configureLayout()
        configureContextMenu()
        viewModel.onChange = { [weak self] in self?.render() }
        render()
    }

    var hasWorkingCopy: Bool { viewModel.workingCopy != nil }
    var workingCopyID: UUID? { viewModel.workingCopy?.id }
    var canRefresh: Bool { hasWorkingCopy && !viewModel.isRefreshing }

    func open(_ workingCopy: WorkingCopy) {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await viewModel.open(workingCopy)
            } catch is CancellationError {
                return
            } catch {
                showRefreshError(error)
            }
        }
    }

    func refreshWorkingCopy() {
        guard canRefresh else { return }
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            do {
                try await self?.viewModel.refresh()
            } catch is CancellationError {
                return
            } catch {
                self?.showRefreshError(error)
            }
        }
    }

    func refreshWhenApplicationBecomesActive() {
        guard view.window != nil, hasWorkingCopy, !viewModel.isRefreshing else { return }
        refreshWorkingCopy()
    }

    func close() {
        refreshTask?.cancel()
        refreshTask = nil
        viewModel.close()
    }

    @objc func refreshRepositoryFromMenu() {
        refreshWorkingCopy()
    }

    @objc private func cancelRefresh() {
        refreshTask?.cancel()
    }

    private func configureOutlineView() {
        for (identifier, title, width) in [
            ("name", "名称", CGFloat(300)),
            ("status", "状态", CGFloat(150)),
            ("size", "大小", CGFloat(90)),
            ("modified", "修改时间", CGFloat(150))
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.minWidth = identifier == "name" ? 180 : 70
            outlineView.addTableColumn(column)
        }
        outlineView.outlineTableColumn = outlineView.tableColumn(withIdentifier: .init("name"))
        outlineView.delegate = self
        outlineView.dataSource = self
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.rowSizeStyle = .medium
        outlineView.allowsMultipleSelection = true
        outlineView.autoresizesOutlineColumn = false
        outlineView.doubleAction = #selector(openSelectedItem)
        outlineView.target = self
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
    }

    private func configureLayout() {
        let header = NSVisualEffectView()
        header.material = .windowBackground
        header.blendingMode = .withinWindow
        let headerDivider = NSBox()
        headerDivider.boxType = .separator

        let statusBar = NSVisualEffectView()
        statusBar.material = .titlebar
        statusBar.blendingMode = .withinWindow
        let statusDivider = NSBox()
        statusDivider.boxType = .separator

        pathLabel.font = .systemFont(ofSize: 13, weight: .medium)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        revealRootButton.title = "Finder"
        revealRootButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "在 Finder 中显示")
        revealRootButton.imagePosition = .imageLeading
        revealRootButton.bezelStyle = .inline
        revealRootButton.target = self
        revealRootButton.action = #selector(revealWorkingCopyRoot)
        repositoryButton.title = "仓库位置"
        repositoryButton.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "打开仓库位置")
        repositoryButton.imagePosition = .imageLeading
        repositoryButton.bezelStyle = .inline
        repositoryButton.target = self
        repositoryButton.action = #selector(openRepositoryLocation)
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        cancelRefreshButton.bezelStyle = .inline
        cancelRefreshButton.controlSize = .small
        cancelRefreshButton.target = self
        cancelRefreshButton.action = #selector(cancelRefresh)
        cancelRefreshButton.isHidden = true
        emptyStateLabel.alignment = .center
        emptyStateLabel.font = .systemFont(ofSize: 15, weight: .medium)
        emptyStateLabel.textColor = .secondaryLabelColor

        view.addSubview(header)
        header.addSubview(pathLabel)
        header.addSubview(revealRootButton)
        header.addSubview(repositoryButton)
        header.addSubview(headerDivider)
        view.addSubview(scrollView)
        view.addSubview(emptyStateLabel)
        view.addSubview(statusBar)
        statusBar.addSubview(statusDivider)
        statusBar.addSubview(progressIndicator)
        statusBar.addSubview(statusLabel)
        statusBar.addSubview(cancelRefreshButton)

        header.snp.makeConstraints { $0.top.leading.trailing.equalToSuperview(); $0.height.equalTo(48) }
        pathLabel.snp.makeConstraints {
            $0.leading.equalToSuperview().inset(16)
            $0.trailing.lessThanOrEqualTo(repositoryButton.snp.leading).offset(-12)
            $0.centerY.equalToSuperview()
        }
        revealRootButton.snp.makeConstraints { $0.trailing.equalToSuperview().inset(12); $0.centerY.equalToSuperview() }
        repositoryButton.snp.makeConstraints { $0.trailing.equalTo(revealRootButton.snp.leading).offset(-8); $0.centerY.equalToSuperview() }
        headerDivider.snp.makeConstraints { $0.leading.trailing.bottom.equalToSuperview(); $0.height.equalTo(1) }
        statusBar.snp.makeConstraints { $0.leading.trailing.bottom.equalToSuperview(); $0.height.equalTo(32) }
        statusDivider.snp.makeConstraints { $0.leading.trailing.top.equalToSuperview(); $0.height.equalTo(1) }
        progressIndicator.snp.makeConstraints { $0.leading.equalToSuperview().inset(12); $0.centerY.equalToSuperview() }
        statusLabel.snp.makeConstraints {
            $0.leading.equalTo(progressIndicator.snp.trailing).offset(8)
            $0.trailing.lessThanOrEqualTo(cancelRefreshButton.snp.leading).offset(-8)
            $0.centerY.equalToSuperview()
        }
        cancelRefreshButton.snp.makeConstraints {
            $0.trailing.equalToSuperview().inset(12)
            $0.centerY.equalToSuperview()
        }
        scrollView.snp.makeConstraints { $0.top.equalTo(header.snp.bottom); $0.leading.trailing.equalToSuperview(); $0.bottom.equalTo(statusBar.snp.top) }
        emptyStateLabel.snp.makeConstraints { $0.center.equalTo(scrollView); $0.width.lessThanOrEqualTo(420) }
    }

    private func configureContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "打开", action: #selector(openSelectedItem), keyEquivalent: "")
        menu.addItem(withTitle: "在 Finder 中显示", action: #selector(revealSelectedItem), keyEquivalent: "")
        for item in menu.items { item.target = self }
        menu.delegate = self
        outlineView.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === outlineView.menu,
              let event = NSApp.currentEvent,
              event.window === view.window else { return }
        let point = outlineView.convert(event.locationInWindow, from: nil)
        let row = outlineView.row(at: point)
        if row >= 0, !outlineView.selectedRowIndexes.contains(row) {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let node = selectedNode, node.entry.isPresent else { return false }
        if menuItem.action == #selector(openSelectedItem) { return true }
        if menuItem.action == #selector(revealSelectedItem) { return true }
        return false
    }

    @objc private func openSelectedItem() {
        guard let node = selectedNode, node.entry.isPresent else { return }
        if node.entry.isDirectory {
            if outlineView.isItemExpanded(node) { outlineView.collapseItem(node) }
            else { outlineView.expandItem(node) }
        } else if !NSWorkspace.shared.open(node.entry.localURL) {
            NSSound.beep()
        }
    }

    @objc private func revealSelectedItem() {
        guard let node = selectedNode, node.entry.isPresent else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.entry.localURL])
    }

    @objc private func revealWorkingCopyRoot() {
        guard let url = viewModel.workingCopy?.localURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func openRepositoryLocation() {
        guard let workingCopy = viewModel.workingCopy else { return }
        onOpenRepositoryLocation?(workingCopy.profileID, workingCopy.repositoryURL)
    }

    private var selectedNode: WorkingCopyTreeNode? {
        guard outlineView.selectedRow >= 0 else { return nil }
        return outlineView.item(atRow: outlineView.selectedRow) as? WorkingCopyTreeNode
    }

    private func captureOutlineState() {
        expandedPaths = Set((0..<outlineView.numberOfRows).compactMap { row in
            guard let node = outlineView.item(atRow: row) as? WorkingCopyTreeNode,
                  outlineView.isItemExpanded(node) else { return nil }
            return node.entry.relativePath
        })
        selectedPaths = Set(outlineView.selectedRowIndexes.compactMap { row in
            (outlineView.item(atRow: row) as? WorkingCopyTreeNode)?.entry.relativePath
        })
    }

    private func render() {
        let workingCopyID = viewModel.workingCopy?.id
        if renderedWorkingCopyID == workingCopyID {
            captureOutlineState()
        } else {
            renderedWorkingCopyID = workingCopyID
            expandedPaths.removeAll()
            selectedPaths.removeAll()
            rootNodes.removeAll()
        }
        pathLabel.stringValue = viewModel.workingCopy.map { "\($0.displayName)  —  \($0.localURL.path)" } ?? "工作副本"
        revealRootButton.isEnabled = viewModel.workingCopy != nil
        repositoryButton.isEnabled = viewModel.workingCopy != nil
        switch viewModel.state {
        case .empty:
            rootNodes = []
            statusLabel.stringValue = "从侧边栏选择一个工作副本"
            emptyStateLabel.stringValue = "尚未选择工作副本"
            emptyStateLabel.isHidden = false
            progressIndicator.stopAnimation(nil)
            cancelRefreshButton.isHidden = true
        case .loading:
            statusLabel.stringValue = "正在检查本地变更…"
            emptyStateLabel.stringValue = viewModel.snapshot == nil ? "正在读取工作副本…" : ""
            emptyStateLabel.isHidden = viewModel.snapshot != nil
            if viewModel.snapshot == nil { rootNodes = [] }
            progressIndicator.startAnimation(nil)
            cancelRefreshButton.isHidden = false
        case .ready:
            progressIndicator.stopAnimation(nil)
            cancelRefreshButton.isHidden = true
            applySnapshot()
        case let .failed(message):
            progressIndicator.stopAnimation(nil)
            cancelRefreshButton.isHidden = true
            statusLabel.stringValue = "刷新失败"
            emptyStateLabel.stringValue = viewModel.snapshot == nil ? message : ""
            emptyStateLabel.isHidden = viewModel.snapshot != nil
        }
        outlineView.reloadData()
        restoreOutlineState()
        onNavigationStateChange?()
    }

    private func applySnapshot() {
        guard let snapshot = viewModel.snapshot else {
            rootNodes = []
            emptyStateLabel.stringValue = "这个工作副本是空的"
            emptyStateLabel.isHidden = false
            return
        }
        rootNodes = WorkingCopyTreeNode.makeTree(entries: snapshot.entries)
        emptyStateLabel.stringValue = "这个工作副本是空的"
        emptyStateLabel.isHidden = !rootNodes.isEmpty
        let time = snapshot.refreshedAt.formatted(date: .omitted, time: .shortened)
        statusLabel.stringValue = snapshot.changedItemCount == 0
            ? "没有本地变更 · 检查于 \(time)"
            : "\(snapshot.changedItemCount) 项本地变更 · 检查于 \(time)"
    }

    private func restoreOutlineState() {
        isRestoringState = true
        func visit(_ nodes: [WorkingCopyTreeNode]) {
            for node in nodes {
                if expandedPaths.contains(node.entry.relativePath) { outlineView.expandItem(node) }
                visit(node.children)
            }
        }
        visit(rootNodes)
        let selectedRows = IndexSet((0..<outlineView.numberOfRows).filter { row in
            guard let node = outlineView.item(atRow: row) as? WorkingCopyTreeNode else { return false }
            return selectedPaths.contains(node.entry.relativePath)
        })
        outlineView.selectRowIndexes(selectedRows, byExtendingSelection: false)
        isRestoringState = false
    }

    private func showRefreshError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法刷新工作副本"
        alert.informativeText = error.localizedDescription
        if let window = view.window { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }
}

extension WorkingCopyViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? WorkingCopyTreeNode)?.children.count ?? rootNodes.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? WorkingCopyTreeNode)?.children ?? rootNodes)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? WorkingCopyTreeNode else { return false }
        return node.entry.isDirectory && !node.children.isEmpty
    }
}

extension WorkingCopyViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? WorkingCopyTreeNode,
              let identifier = tableColumn?.identifier else { return nil }
        let cellIdentifier = NSUserInterfaceItemIdentifier("WorkingCopyCell.\(identifier.rawValue)")
        let cell = outlineView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSTableCellView
            ?? makeCell(identifier: cellIdentifier, showsImage: identifier.rawValue == "name")
        switch identifier.rawValue {
        case "name":
            cell.textField?.stringValue = node.entry.localURL.lastPathComponent
            cell.imageView?.image = NSWorkspace.shared.icon(forFile: node.entry.localURL.path)
            cell.textField?.textColor = node.entry.isPresent ? .labelColor : .secondaryLabelColor
        case "status":
            cell.textField?.stringValue = node.entry.status?.displayName ?? "—"
            cell.textField?.textColor = node.entry.status == nil ? .secondaryLabelColor : .systemOrange
        case "size":
            cell.textField?.stringValue = node.entry.byteSize.map {
                ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
            } ?? "—"
        case "modified":
            cell.textField?.stringValue = node.entry.modifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—"
        default:
            cell.textField?.stringValue = ""
        }
        return cell
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isRestoringState,
              let node = notification.userInfo?["NSObject"] as? WorkingCopyTreeNode else { return }
        expandedPaths.insert(node.entry.relativePath)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isRestoringState,
              let node = notification.userInfo?["NSObject"] as? WorkingCopyTreeNode else { return }
        expandedPaths.remove(node.entry.relativePath)
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier, showsImage: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingMiddle
        cell.textField = label
        cell.addSubview(label)
        if showsImage {
            let imageView = NSImageView()
            imageView.imageScaling = .scaleProportionallyDown
            cell.imageView = imageView
            cell.addSubview(imageView)
            imageView.snp.makeConstraints { $0.leading.centerY.equalToSuperview(); $0.width.height.equalTo(18) }
            label.snp.makeConstraints { $0.leading.equalTo(imageView.snp.trailing).offset(6); $0.trailing.centerY.equalToSuperview() }
        } else {
            label.snp.makeConstraints { $0.leading.trailing.centerY.equalToSuperview() }
        }
        return cell
    }
}

@MainActor
private final class WorkingCopyTreeNode {
    let entry: WorkingCopyLocalEntry
    var children: [WorkingCopyTreeNode] = []

    init(entry: WorkingCopyLocalEntry) {
        self.entry = entry
    }

    static func makeTree(entries: [WorkingCopyLocalEntry]) -> [WorkingCopyTreeNode] {
        var nodesByPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.relativePath, WorkingCopyTreeNode(entry: $0)) })
        for entry in entries {
            var workingCopyRoot = entry.localURL
            for _ in entry.relativePath.split(separator: "/") {
                workingCopyRoot.deleteLastPathComponent()
            }
            var parentPath = (entry.relativePath as NSString).deletingLastPathComponent
            while !parentPath.isEmpty, nodesByPath[parentPath] == nil {
                let parentURL = workingCopyRoot.appendingPathComponent(parentPath, isDirectory: true)
                let synthetic = WorkingCopyLocalEntry(
                    localURL: parentURL,
                    relativePath: parentPath,
                    isDirectory: true,
                    byteSize: nil,
                    modifiedAt: nil,
                    status: nil,
                    isPresent: FileManager.default.fileExists(atPath: parentURL.path)
                )
                nodesByPath[parentPath] = WorkingCopyTreeNode(entry: synthetic)
                parentPath = (parentPath as NSString).deletingLastPathComponent
            }
        }
        var roots: [WorkingCopyTreeNode] = []
        for (path, node) in nodesByPath {
            let parentPath = (path as NSString).deletingLastPathComponent
            if parentPath.isEmpty { roots.append(node) }
            else { nodesByPath[parentPath]?.children.append(node) }
        }
        func sort(_ nodes: inout [WorkingCopyTreeNode]) {
            nodes.sort {
                if $0.entry.isDirectory != $1.entry.isDirectory { return $0.entry.isDirectory }
                return $0.entry.localURL.lastPathComponent.localizedStandardCompare($1.entry.localURL.lastPathComponent) == .orderedAscending
            }
            for node in nodes { sort(&node.children) }
        }
        sort(&roots)
        return roots
    }
}
