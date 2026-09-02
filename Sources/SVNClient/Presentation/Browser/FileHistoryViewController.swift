import AppKit
import SnapKit

@MainActor
final class FileHistoryViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onDownload: ((SVNLogEntry) -> Void)?
    var onOpen: ((SVNLogEntry) -> Void)?
    var onRestore: ((SVNLogEntry) -> Void)?
    var onClose: (() -> Void)?

    private let history: BrowserFileHistory
    private let tableView = NSTableView()
    private let downloadButton = NSButton(title: "下载…", target: nil, action: nil)
    private let openButton = NSButton(title: "打开", target: nil, action: nil)
    private let restoreButton = NSButton(title: "恢复此版本…", target: nil, action: nil)

    init(history: BrowserFileHistory) {
        self.history = history
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
        configureView()
        configureTable()
        configureLayout()
        updateButtons()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !history.entries.isEmpty else { return }
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        updateButtons()
    }

    private func configureView() {
        downloadButton.target = self
        downloadButton.action = #selector(downloadSelected)
        openButton.target = self
        openButton.action = #selector(openSelected)
        restoreButton.target = self
        restoreButton.action = #selector(restoreSelected)
        restoreButton.hasDestructiveAction = true
    }

    private func configureTable() {
        let columns: [(String, String, CGFloat)] = [
            ("revision", "版本", 80),
            ("author", "修改人", 120),
            ("date", "时间", 165),
            ("message", "提交说明", 310)
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.minWidth = identifier == "message" ? 180 : 70
            tableView.addTableColumn(column)
        }
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowSizeStyle = .medium
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.target = self
        tableView.doubleAction = #selector(openSelected)
    }

    private func configureLayout() {
        let title = NSTextField(labelWithString: "“\(history.displayName)”的历史版本")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "当前版本 r\(history.currentRevision) · 最多显示 \(history.entries.count) 条记录")
        subtitle.textColor = .secondaryLabelColor

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .bezelBorder

        let closeButton = NSButton(title: "关闭", target: self, action: #selector(closeWindow))
        let footer = NSStackView(views: [restoreButton, NSView(), downloadButton, openButton, closeButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8

        for subview in [title, subtitle, scrollView, footer] {
            view.addSubview(subview)
        }
        title.snp.makeConstraints {
            $0.top.equalToSuperview().inset(18)
            $0.leading.trailing.equalToSuperview().inset(20)
        }
        subtitle.snp.makeConstraints {
            $0.top.equalTo(title.snp.bottom).offset(5)
            $0.leading.trailing.equalTo(title)
        }
        scrollView.snp.makeConstraints {
            $0.top.equalTo(subtitle.snp.bottom).offset(14)
            $0.leading.trailing.equalToSuperview().inset(20)
            $0.bottom.equalTo(footer.snp.top).offset(-14)
        }
        footer.snp.makeConstraints {
            $0.leading.trailing.bottom.equalToSuperview().inset(20)
            $0.height.equalTo(32)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        history.entries.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard history.entries.indices.contains(row), let identifier = tableColumn?.identifier.rawValue else {
            return nil
        }
        let entry = history.entries[row]
        let value: String
        switch identifier {
        case "revision": value = "r\(entry.revision)"
        case "author": value = entry.author.flatMap { $0.isEmpty ? nil : $0 } ?? "—"
        case "date": value = entry.date?.formatted(date: .abbreviated, time: .shortened) ?? "—"
        default:
            let message = entry.message.replacingOccurrences(of: "\n", with: " ")
            value = message.isEmpty ? "—" : message
        }
        let label = NSTextField(labelWithString: value)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = value
        let cell = NSTableCellView()
        cell.addSubview(label)
        label.snp.makeConstraints {
            $0.leading.trailing.equalToSuperview().inset(4)
            $0.centerY.equalToSuperview()
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }

    private var selectedEntry: SVNLogEntry? {
        guard history.entries.indices.contains(tableView.selectedRow) else { return nil }
        return history.entries[tableView.selectedRow]
    }

    private func updateButtons() {
        let entry = selectedEntry
        downloadButton.isEnabled = entry != nil
        openButton.isEnabled = entry != nil
        restoreButton.isEnabled = entry.map { $0.revision != history.currentRevision } ?? false
    }

    @objc private func downloadSelected() {
        guard let selectedEntry else { return }
        onDownload?(selectedEntry)
    }

    @objc private func openSelected() {
        guard let selectedEntry else { return }
        onOpen?(selectedEntry)
    }

    @objc private func restoreSelected() {
        guard let selectedEntry, selectedEntry.revision != history.currentRevision else { return }
        onRestore?(selectedEntry)
    }

    @objc private func closeWindow() {
        view.window?.close()
        onClose?()
    }
}
