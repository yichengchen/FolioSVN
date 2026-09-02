import AppKit
import SnapKit
import UniformTypeIdentifiers

@MainActor
final class BrowserViewController: NSViewController, NSMenuItemValidation, NSMenuDelegate {
    var onNavigationStateChange: (() -> Void)?

    private let viewModel: BrowserViewModel
    private let breadcrumbStack = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let cancelActivityButton = NSButton(title: "取消", target: nil, action: nil)
    private let transferButton = NSButton(title: "传输", target: nil, action: nil)
    private let emptyStateLabel = NSTextField(wrappingLabelWithString: "")
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private var favoriteMenuItem: NSMenuItem?
    private var operationTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    init(viewModel: BrowserViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let dropView = BrowserUploadDropView()
        dropView.canAcceptDrop = { [weak self] in
            self?.canModifyRepository == true
        }
        dropView.onDrop = { [weak self] urls in
            self?.handleFilesForUpload(urls)
        }
        view = dropView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureTableView()
        configureLayout()
        configureContextMenu()
        viewModel.onChange = { [weak self] in
            self?.render()
        }
        render()
    }

    var canGoBack: Bool { viewModel.canGoBack }
    var canGoForward: Bool { viewModel.canGoForward }
    var canModifyRepository: Bool {
        viewModel.currentURL != nil && !viewModel.isBusy && !viewModel.isShowingSearchResults
    }
    var hasRepositoryConnection: Bool { viewModel.currentURL != nil }
    var currentSearchQuery: String { viewModel.searchQuery }

    func navigateBack() { run { try await self.viewModel.goBack() } }
    func navigateForward() { run { try await self.viewModel.goForward() } }
    func refreshRepository() { run { try await self.viewModel.refresh() } }
    func createFolder() { promptForNewFolder() }
    func uploadFiles() { chooseFilesForUpload() }
    func refreshSearchIndex() { run { try await self.viewModel.refreshSearchIndex() } }

    func updateSearch(query: String, scope: BrowserViewModel.SearchScope) {
        searchTask?.cancel()
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            viewModel.clearSearch()
            return
        }
        searchTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                try await viewModel.search(query: query, scope: scope)
            } catch is CancellationError {
                // A newer keystroke superseded this query.
            } catch {
                self?.presentError(message: error.localizedDescription)
            }
        }
    }

    private func configureTableView() {
        let columns: [(String, String, CGFloat)] = [
            ("name", "名称", 210),
            ("type", "类型", 65),
            ("size", "大小", 70),
            ("modified", "修改时间", 120),
            ("author", "修改人", 75),
            ("revision", "版本", 60),
            ("location", "位置", 180)
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.minWidth = identifier == "name" ? 140 : 55
            column.sortDescriptorPrototype = NSSortDescriptor(key: identifier, ascending: true)
            tableView.addTableColumn(column)
        }
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowSizeStyle = .medium
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.allowsMultipleSelection = false
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.doubleAction = #selector(openSelectedItem)
        tableView.target = self
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
    }

    private func configureContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "打开", action: #selector(openSelectedItem), keyEquivalent: "")
        menu.addItem(withTitle: "下载…", action: #selector(downloadSelectedItem), keyEquivalent: "")
        menu.addItem(withTitle: "替换…", action: #selector(replaceSelectedItem), keyEquivalent: "")
        let favoriteItem = menu.addItem(withTitle: "添加到收藏", action: #selector(toggleFavoriteForSelectedItem), keyEquivalent: "")
        favoriteMenuItem = favoriteItem
        menu.addItem(.separator())
        menu.addItem(withTitle: "重命名…", action: #selector(renameSelectedItem), keyEquivalent: "")
        menu.addItem(withTitle: "删除", action: #selector(deleteSelectedItem), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "查看信息", action: #selector(showSelectedItemInfo), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "复制显示路径", action: #selector(copySelectedDisplayPath), keyEquivalent: "")
        menu.addItem(withTitle: "复制仓库 URL", action: #selector(copySelectedRepositoryURL), keyEquivalent: "")
        for item in menu.items { item.target = self }
        menu.delegate = self
        tableView.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === tableView.menu else { return }
        if let event = NSApp.currentEvent, event.window === view.window {
            let point = tableView.convert(event.locationInWindow, from: nil)
            let clickedRow = tableView.row(at: point)
            if clickedRow >= 0 {
                tableView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
            }
        }
        guard let row = selectedRow else { return }
        favoriteMenuItem?.title = viewModel.isFavorite(row) ? "从收藏移除" : "添加到收藏"
    }

    private func configureLayout() {
        breadcrumbStack.orientation = .horizontal
        breadcrumbStack.alignment = .centerY
        breadcrumbStack.spacing = 2

        let breadcrumbContainer = NSVisualEffectView()
        breadcrumbContainer.material = .windowBackground
        breadcrumbContainer.blendingMode = .withinWindow
        let breadcrumbDivider = NSBox()
        breadcrumbDivider.boxType = .separator

        let statusBar = NSVisualEffectView()
        statusBar.material = .titlebar
        statusBar.blendingMode = .withinWindow
        let statusDivider = NSBox()
        statusDivider.boxType = .separator

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        cancelActivityButton.bezelStyle = .inline
        cancelActivityButton.controlSize = .small
        cancelActivityButton.target = self
        cancelActivityButton.action = #selector(cancelCurrentActivity)
        cancelActivityButton.isHidden = true
        transferButton.bezelStyle = .inline
        transferButton.controlSize = .small
        transferButton.image = NSImage(
            systemSymbolName: "arrow.up.arrow.down",
            accessibilityDescription: "传输任务"
        )
        transferButton.imagePosition = .imageLeading
        transferButton.target = self
        transferButton.action = #selector(showTransferTasks)

        emptyStateLabel.alignment = .center
        emptyStateLabel.font = .systemFont(ofSize: 15, weight: .medium)
        emptyStateLabel.textColor = .secondaryLabelColor

        view.addSubview(breadcrumbContainer)
        breadcrumbContainer.addSubview(breadcrumbStack)
        breadcrumbContainer.addSubview(breadcrumbDivider)
        view.addSubview(scrollView)
        view.addSubview(emptyStateLabel)
        view.addSubview(statusBar)
        statusBar.addSubview(statusDivider)
        statusBar.addSubview(progressIndicator)
        statusBar.addSubview(statusLabel)
        statusBar.addSubview(transferButton)
        statusBar.addSubview(cancelActivityButton)

        breadcrumbContainer.snp.makeConstraints {
            $0.top.leading.trailing.equalToSuperview()
            $0.height.equalTo(48)
        }
        breadcrumbStack.snp.makeConstraints {
            $0.leading.trailing.equalToSuperview().inset(16)
            $0.centerY.equalToSuperview()
        }
        breadcrumbDivider.snp.makeConstraints {
            $0.leading.trailing.bottom.equalToSuperview()
            $0.height.equalTo(1)
        }
        scrollView.snp.makeConstraints {
            $0.top.equalTo(breadcrumbContainer.snp.bottom)
            $0.leading.trailing.equalToSuperview()
            $0.bottom.equalTo(statusBar.snp.top)
        }
        emptyStateLabel.snp.makeConstraints {
            $0.center.equalTo(scrollView)
            $0.width.lessThanOrEqualTo(360)
        }
        statusBar.snp.makeConstraints {
            $0.leading.trailing.bottom.equalToSuperview()
            $0.height.equalTo(32)
        }
        statusDivider.snp.makeConstraints {
            $0.top.leading.trailing.equalToSuperview()
            $0.height.equalTo(1)
        }
        progressIndicator.snp.makeConstraints {
            $0.leading.equalToSuperview().inset(12)
            $0.centerY.equalToSuperview()
        }
        statusLabel.snp.makeConstraints {
            $0.leading.equalTo(progressIndicator.snp.trailing).offset(7)
            $0.centerY.equalToSuperview()
            $0.trailing.lessThanOrEqualTo(transferButton.snp.leading).offset(-8)
        }
        transferButton.snp.makeConstraints {
            $0.trailing.equalTo(cancelActivityButton.snp.leading).offset(-4)
            $0.centerY.equalToSuperview()
        }
        cancelActivityButton.snp.makeConstraints {
            $0.trailing.equalToSuperview().inset(10)
            $0.centerY.equalToSuperview()
        }
    }

    private func render() {
        statusLabel.stringValue = viewModel.statusText
        transferButton.title = viewModel.activeTransferCount > 0
            ? "传输（\(viewModel.activeTransferCount)）"
            : "传输"
        viewModel.isBusy ? progressIndicator.startAnimation(nil) : progressIndicator.stopAnimation(nil)
        cancelActivityButton.isHidden = !viewModel.isCancellable
        tableView.reloadData()
        tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("location"))?.isHidden = !viewModel.isShowingSearchResults
        rebuildBreadcrumbs()

        if viewModel.isShowingSearchResults {
            emptyStateLabel.stringValue = "没有找到匹配的文件或文件夹"
            emptyStateLabel.isHidden = !viewModel.rows.isEmpty
        } else {
            switch viewModel.state {
        case .disconnected:
            emptyStateLabel.stringValue = "添加或选择一个 SVN 服务器开始浏览"
            emptyStateLabel.isHidden = false
        case .loading:
            emptyStateLabel.isHidden = !viewModel.rows.isEmpty
            emptyStateLabel.stringValue = "正在读取目录…"
        case .loaded where viewModel.rows.isEmpty:
            emptyStateLabel.stringValue = "这个文件夹是空的\n可以上传文件或新建文件夹"
            emptyStateLabel.isHidden = false
        case let .failed(message):
            emptyStateLabel.stringValue = "无法读取此位置\n\(message)"
            emptyStateLabel.isHidden = false
        default:
            emptyStateLabel.isHidden = true
            }
        }
        onNavigationStateChange?()
    }

    private func rebuildBreadcrumbs() {
        breadcrumbStack.arrangedSubviews.forEach {
            breadcrumbStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        if viewModel.breadcrumbs.isEmpty {
            let label = NSTextField(labelWithString: "尚未连接")
            label.textColor = .secondaryLabelColor
            breadcrumbStack.addArrangedSubview(label)
            return
        }
        for (index, breadcrumb) in viewModel.breadcrumbs.enumerated() {
            if index > 0 {
                let separator = NSImageView(image: NSImage(
                    systemSymbolName: "chevron.right",
                    accessibilityDescription: nil
                ) ?? NSImage())
                separator.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
                separator.contentTintColor = .tertiaryLabelColor
                breadcrumbStack.addArrangedSubview(separator)
            }
            let button = BreadcrumbButton(title: breadcrumb.title, url: breadcrumb.url)
            button.bezelStyle = .inline
            button.font = .systemFont(ofSize: 13, weight: index == viewModel.breadcrumbs.count - 1 ? .semibold : .regular)
            button.target = self
            button.action = #selector(openBreadcrumb(_:))
            breadcrumbStack.addArrangedSubview(button)
        }
        breadcrumbStack.addArrangedSubview(NSView())
    }

    @objc private func openBreadcrumb(_ sender: BreadcrumbButton) {
        run { try await self.viewModel.navigate(to: sender.url) }
    }

    private var selectedRow: BrowserRow? {
        guard tableView.selectedRow >= 0, viewModel.rows.indices.contains(tableView.selectedRow) else { return nil }
        return viewModel.rows[tableView.selectedRow]
    }

    @objc private func openSelectedItem() {
        guard let row = selectedRow else { return }
        if row.kind == .directory {
            run { try await self.viewModel.openDirectory(row) }
        } else {
            run {
                let localURL = try await self.viewModel.localURLForOpening(row)
                guard NSWorkspace.shared.open(localURL) else {
                    throw BrowserOperationError.noApplication
                }
            }
        }
    }

    @objc private func downloadSelectedItem() {
        guard let row = selectedRow else { return }
        let panel = NSSavePanel()
        panel.title = row.kind == .directory ? "下载文件夹" : "下载文件"
        panel.nameFieldStringValue = row.name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }
        let overwrite = FileManager.default.fileExists(atPath: destinationURL.path)
        guard let resolved = resolveExistingDownload(destinationURL, overwrite: overwrite) else { return }
        run { try await self.viewModel.download(row, to: resolved.url, overwrite: resolved.overwrite) }
    }

    private func chooseFilesForUpload() {
        guard canModifyRepository else { return }
        let panel = NSOpenPanel()
        panel.title = "选择要上传的文件"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        handleFilesForUpload(panel.urls)
    }

    private func handleFilesForUpload(_ urls: [URL]) {
        guard canModifyRepository, !urls.isEmpty else { return }
        let files = Array(Dictionary(grouping: urls.map(\.standardizedFileURL), by: \.path).compactMap(\.value.first))
        let invalidURL = files.first { url in
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile != true
        }
        guard invalidURL == nil else {
            presentError(message: "当前仅支持上传文件，暂不支持直接拖入文件夹。")
            return
        }

        let existing = Dictionary(uniqueKeysWithValues: viewModel.rows.map { ($0.name, $0) })
        let conflicts = files.compactMap { localURL in
            existing[localURL.lastPathComponent].map { row in (localURL, row) }
        }
        if files.count == 1, let (localURL, row) = conflicts.first, row.kind == .file {
            confirmReplace(row: row, localURL: localURL)
            return
        }
        if let conflict = conflicts.first {
            presentError(message: "“\(conflict.0.lastPathComponent)”已存在。请单独选择该文件执行替换，其他文件尚未上传。")
            return
        }

        let totalBytes = files.reduce(Int64(0)) { partial, url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            return partial + Int64(values?.fileSize ?? 0)
        }
        let details = "将上传 \(files.count) 个文件（\(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))），一次提交到当前文件夹。"
        guard let message = prompt(
            title: "确认上传",
            message: details,
            fieldLabel: "提交说明",
            initialValue: "上传 \(files.count) 个文件",
            confirmTitle: "上传"
        ) else { return }
        run { _ = try await self.viewModel.upload(files: files, message: message) }
    }

    @objc private func replaceSelectedItem() {
        guard let row = selectedRow, row.kind == .file else { return }
        let panel = NSOpenPanel()
        panel.title = "选择替换文件"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let localURL = panel.url else { return }
        confirmReplace(row: row, localURL: localURL)
    }

    @objc private func toggleFavoriteForSelectedItem() {
        guard let row = selectedRow else { return }
        run { _ = try await self.viewModel.toggleFavorite(row) }
    }

    private func confirmReplace(row: BrowserRow, localURL: URL) {
        let values = try? localURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let localSize = ByteCountFormatter.string(fromByteCount: Int64(values?.fileSize ?? 0), countStyle: .file)
        let localDate = values?.contentModificationDate?.formatted(date: .abbreviated, time: .shortened) ?? "未知"
        let nameWarning = localURL.lastPathComponent == row.name
            ? ""
            : "\n本地文件名不同；内容会覆盖目标，但仓库名称仍保持“\(row.name)”。"
        let details = "仓库文件：\(row.name) · \(row.size) · \(row.revisionText)\n本地文件：\(localURL.lastPathComponent) · \(localSize) · \(localDate)\(nameWarning)"
        guard let message = prompt(
            title: "替换“\(row.name)”？",
            message: details,
            fieldLabel: "提交说明",
            initialValue: "更新：\(row.name)",
            confirmTitle: "替换文件",
            destructive: true
        ) else { return }
        run { _ = try await self.viewModel.replace(row, with: localURL, message: message) }
    }

    private func promptForNewFolder() {
        guard canModifyRepository else { return }
        guard let name = prompt(
            title: "新建文件夹",
            message: "在当前目录创建一个新文件夹。",
            fieldLabel: "文件夹名称",
            initialValue: "新建文件夹",
            confirmTitle: "创建"
        ), validateName(name) else { return }
        guard !viewModel.rows.contains(where: { $0.name == name }) else {
            presentError(message: "当前文件夹已存在同名项目。")
            return
        }
        run { _ = try await self.viewModel.createDirectory(name: name, message: "新建文件夹：\(name)") }
    }

    @objc private func renameSelectedItem() {
        guard let row = selectedRow else { return }
        guard let name = prompt(
            title: "重命名“\(row.name)”",
            message: "重命名会保留原路径的版本历史。",
            fieldLabel: "新名称",
            initialValue: row.name,
            confirmTitle: "重命名"
        ), name != row.name, validateName(name) else { return }
        guard !viewModel.rows.contains(where: { $0.name == name }) else {
            presentError(message: "当前文件夹已存在同名项目。")
            return
        }
        run { _ = try await self.viewModel.rename(row, to: name, message: "重命名：\(row.name) → \(name)") }
    }

    @objc private func deleteSelectedItem() {
        guard let row = selectedRow else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除“\(row.name)”？"
        alert.informativeText = row.kind == .directory
            ? "该文件夹及其中的全部内容都会从当前版本删除。操作会提交到仓库，仍可从历史追溯。"
            : "此操作会提交到仓库。文件仍可从历史找回，但当前目录中将不再显示。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run { _ = try await self.viewModel.delete(row, message: "删除：\(row.name)") }
    }

    @objc private func showSelectedItemInfo() {
        guard let row = selectedRow else { return }
        run {
            let info = try await self.viewModel.info(for: row)
            self.presentInfo(info)
        }
    }

    private func presentInfo(_ info: SVNItemInfo) {
        let propertyText = info.properties.isEmpty
            ? "无"
            : info.properties.sorted(by: { $0.key < $1.key }).map { "\($0.key) = \($0.value)" }.joined(separator: "\n")
        let text = """
        名称：\(info.name)
        仓库 URL：\(info.url.absoluteString)
        类型：\(info.kind == .directory ? "文件夹" : "文件")
        大小：\(info.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
        最后修改：\(info.updatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—")
        修改人：\(info.author ?? "—")
        最后修改版本：\(info.lastChangedRevision.map { "r\($0)" } ?? "—")

        SVN 属性：
        \(propertyText)
        """
        let alert = NSAlert()
        alert.messageText = "文件信息"
        alert.informativeText = text
        alert.addButton(withTitle: "完成")
        alert.addButton(withTitle: "复制信息")
        if alert.runModal() == .alertSecondButtonReturn {
            copy(text)
        }
    }

    @objc private func copySelectedDisplayPath() {
        guard let row = selectedRow else { return }
        copy(viewModel.displayPath(for: row))
    }

    @objc private func copySelectedRepositoryURL() {
        guard let row = selectedRow else { return }
        copy(viewModel.itemURL(for: row).absoluteString)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func resolveExistingDownload(_ url: URL, overwrite: Bool) -> (url: URL, overwrite: Bool)? {
        guard overwrite else { return (url, false) }
        let alert = NSAlert()
        alert.messageText = "“\(url.lastPathComponent)”已经存在"
        alert.informativeText = "可以替换现有项目、自动保留两者，或取消下载。"
        alert.addButton(withTitle: "替换")
        alert.addButton(withTitle: "保留两者")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return (url, true)
        case .alertSecondButtonReturn:
            return (uniqueSiblingURL(for: url), false)
        default:
            return nil
        }
    }

    private func uniqueSiblingURL(for url: URL) -> URL {
        let directory = url.deletingLastPathComponent()
        let extensionName = url.pathExtension
        let baseName = extensionName.isEmpty
            ? url.lastPathComponent
            : String(url.lastPathComponent.dropLast(extensionName.count + 1))
        for index in 2...999 {
            let candidateName = extensionName.isEmpty
                ? "\(baseName) \(index)"
                : "\(baseName) \(index).\(extensionName)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(baseName)-\(UUID().uuidString).\(extensionName)")
    }

    private func prompt(
        title: String,
        message: String,
        fieldLabel: String,
        initialValue: String,
        confirmTitle: String,
        destructive: Bool = false
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = destructive

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 52))
        let label = NSTextField(labelWithString: fieldLabel)
        let field = NSTextField(string: initialValue)
        container.addSubview(label)
        container.addSubview(field)
        label.snp.makeConstraints { $0.top.leading.trailing.equalToSuperview() }
        field.snp.makeConstraints { $0.top.equalTo(label.snp.bottom).offset(6); $0.leading.trailing.equalToSuperview(); $0.height.equalTo(24) }
        alert.accessoryView = container

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func validateName(_ name: String) -> Bool {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\0") else {
            presentError(message: "名称不能为空，也不能包含“/”或使用“.”、“..”。")
            return false
        }
        return true
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        operationTask = Task { @MainActor [weak self] in
            do {
                try await operation()
            } catch is CancellationError {
                // User-cancelled reads and downloads are expected and leave no final partial file.
            } catch {
                self?.presentError(message: error.localizedDescription)
            }
            self?.operationTask = nil
        }
    }

    @objc private func cancelCurrentActivity() {
        operationTask?.cancel()
        searchTask?.cancel()
    }

    @objc private func showTransferTasks() {
        let menu = NSMenu(title: "传输任务")
        if viewModel.transfers.isEmpty {
            let item = NSMenuItem(title: "暂无传输记录", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for transfer in viewModel.transfers.prefix(10) {
                let item = NSMenuItem(
                    title: "\(transfer.title) · \(transfer.stateText)",
                    action: nil,
                    keyEquivalent: ""
                )
                item.subtitle = transfer.statusDetail
                item.image = NSImage(
                    systemSymbolName: transferSymbolName(transfer),
                    accessibilityDescription: transfer.stateText
                )
                item.isEnabled = false
                menu.addItem(item)
            }
        }
        if viewModel.isCancellable {
            menu.addItem(.separator())
            let cancel = menu.addItem(
                withTitle: "取消当前传输",
                action: #selector(cancelCurrentActivity),
                keyEquivalent: ""
            )
            cancel.target = self
        }
        if viewModel.transfers.contains(where: { $0.state != .running }) {
            menu.addItem(.separator())
            let clear = menu.addItem(
                withTitle: "清除已完成记录",
                action: #selector(clearFinishedTransfers),
                keyEquivalent: ""
            )
            clear.target = self
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: transferButton.bounds.maxY + 4), in: transferButton)
    }

    @objc private func clearFinishedTransfers() {
        viewModel.clearFinishedTransfers()
    }

    private func transferSymbolName(_ transfer: BrowserTransfer) -> String {
        switch transfer.state {
        case .running: return "hourglass"
        case .completed: return "checkmark.circle"
        case .cancelled: return "xmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private func presentError(message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "操作未完成"
        alert.informativeText = message
        alert.runModal()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let row = selectedRow, !viewModel.isBusy else { return false }
        if viewModel.isShowingSearchResults {
            switch menuItem.action {
            case #selector(renameSelectedItem), #selector(deleteSelectedItem), #selector(replaceSelectedItem):
                return false
            default:
                break
            }
        }
        if menuItem.action == #selector(replaceSelectedItem) {
            return row.kind == .file
        }
        return true
    }
}

extension BrowserViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { viewModel.rows.count }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard !viewModel.isBusy, viewModel.rows.indices.contains(row) else { return nil }
        let browserRow = viewModel.rows[row]
        guard let downloadRequest = viewModel.downloadRequest(for: browserRow) else { return nil }
        let fileType = browserRow.kind == .directory
            ? UTType.folder.identifier
            : UTType(filenameExtension: browserRow.url.pathExtension)?.identifier ?? UTType.data.identifier
        let provider = NSFilePromiseProvider(fileType: fileType, delegate: self)
        provider.userInfo = BrowserFilePromise(row: browserRow, downloadRequest: downloadRequest)
        return provider
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: any NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard canModifyRepository, !localFileURLs(from: info.draggingPasteboard).isEmpty else { return [] }
        tableView.setDropRow(viewModel.rows.count, dropOperation: .above)
        return .copy
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: any NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        let urls = localFileURLs(from: info.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        handleFilesForUpload(urls)
        return true
    }

    private func localFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL])?
            .map { $0 as URL } ?? []
    }
}

extension BrowserViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else { return nil }
        let browserRow = viewModel.rows[row]
        if tableColumn.identifier.rawValue == "name" {
            let identifier = NSUserInterfaceItemIdentifier("BrowserNameCell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? BrowserNameCell
                ?? BrowserNameCell(identifier: identifier)
            cell.configure(row: browserRow)
            return cell
        }

        let identifier = NSUserInterfaceItemIdentifier("BrowserCell-\(tableColumn.identifier.rawValue)")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? NSTableCellView()
        cell.identifier = identifier
        cell.textField = cell.textField ?? NSTextField(labelWithString: "")
        if cell.textField?.superview == nil, let textField = cell.textField {
            cell.addSubview(textField)
            textField.lineBreakMode = .byTruncatingTail
            textField.snp.makeConstraints { $0.leading.trailing.equalToSuperview().inset(6); $0.centerY.equalToSuperview() }
        }
        cell.textField?.stringValue = browserRow.value(for: tableColumn.identifier.rawValue)
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first, let column = descriptor.key else { return }
        viewModel.sort(column: column, ascending: descriptor.ascending)
    }

    func tableView(
        _ tableView: NSTableView,
        draggingSession session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }
}

extension BrowserViewController: NSFilePromiseProviderDelegate {
    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        (filePromiseProvider.userInfo as? BrowserFilePromise)?.row.name ?? "SVN 下载"
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let promise = filePromiseProvider.userInfo as? BrowserFilePromise else {
            completionHandler(BrowserOperationError.invalidFilePromise)
            return
        }
        let downloadRequest = promise.downloadRequest
        let completion = FilePromiseCompletion(completionHandler)
        // Finder supplies the complete, coordinated destination URL, including the promised filename.
        let destinationURL = url
        Task { @MainActor [weak self] in
            self?.startFilePromiseDownload(
                downloadRequest,
                to: destinationURL,
                completion: completion
            ) ?? completion.call(CancellationError())
        }
    }
}

private extension BrowserViewController {
    func startFilePromiseDownload(
        _ request: BrowserDownloadRequest,
        to destinationURL: URL,
        completion: FilePromiseCompletion
    ) {
        let task = Task { @MainActor [weak self] in
            guard let self else {
                completion.call(CancellationError())
                return
            }
            defer { self.operationTask = nil }
            do {
                try await viewModel.download(request, to: destinationURL, overwrite: false)
                completion.call(nil)
            } catch {
                completion.call(error)
            }
        }
        operationTask = task
    }
}

private final class BrowserFilePromise: NSObject {
    let row: BrowserRow
    let downloadRequest: BrowserDownloadRequest

    init(row: BrowserRow, downloadRequest: BrowserDownloadRequest) {
        self.row = row
        self.downloadRequest = downloadRequest
    }
}

private final class FilePromiseCompletion: @unchecked Sendable {
    private let handler: (Error?) -> Void

    init(_ handler: @escaping (Error?) -> Void) {
        self.handler = handler
    }

    func call(_ error: Error?) {
        handler(error)
    }
}

@MainActor
private final class BrowserUploadDropView: NSView {
    var canAcceptDrop: (() -> Bool)?
    var onDrop: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard canAcceptDrop?() == true, !fileURLs(from: sender.draggingPasteboard).isEmpty else { return [] }
        return .copy
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        canAcceptDrop?() == true && !fileURLs(from: sender.draggingPasteboard).isEmpty
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

    private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL])?
            .map { $0 as URL } ?? []
    }
}

private final class BrowserNameCell: NSTableCellView {
    private let symbolView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        imageView = symbolView
        textField = titleLabel
        addSubview(symbolView)
        addSubview(titleLabel)
        symbolView.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        symbolView.snp.makeConstraints {
            $0.leading.equalToSuperview().inset(7)
            $0.centerY.equalToSuperview()
            $0.width.height.equalTo(18)
        }
        titleLabel.snp.makeConstraints {
            $0.leading.equalTo(symbolView.snp.trailing).offset(7)
            $0.trailing.equalToSuperview().inset(6)
            $0.centerY.equalToSuperview()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(row: BrowserRow) {
        titleLabel.stringValue = row.name
        symbolView.image = NSImage(
            systemSymbolName: row.kind == .directory ? "folder.fill" : "doc.fill",
            accessibilityDescription: row.kind == .directory ? "文件夹" : "文件"
        )
        symbolView.contentTintColor = row.kind == .directory ? .systemBlue : .secondaryLabelColor
    }
}

private final class BreadcrumbButton: NSButton {
    let url: URL

    init(title: String, url: URL) {
        self.url = url
        super.init(frame: .zero)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private enum BrowserOperationError: LocalizedError {
    case noApplication
    case invalidFilePromise

    var errorDescription: String? {
        switch self {
        case .noApplication:
            "找不到可以打开该文件格式的应用"
        case .invalidFilePromise:
            "无法创建拖出下载任务"
        }
    }
}
