import AppKit
import SnapKit

@MainActor
final class CheckoutProgressViewController: NSViewController {
    var onCancel: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "正在检出工作副本…")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)

    init(name: String, destinationURL: URL) {
        super.init(nibName: nil, bundle: nil)
        titleLabel.stringValue = "正在检出“\(name)”…"
        detailLabel.stringValue = destinationURL.path
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 150))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = true
        progressIndicator.startAnimation(nil)
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancel)

        view.addSubview(titleLabel)
        view.addSubview(detailLabel)
        view.addSubview(progressIndicator)
        view.addSubview(cancelButton)
        titleLabel.snp.makeConstraints { $0.top.leading.trailing.equalToSuperview().inset(24) }
        detailLabel.snp.makeConstraints { $0.top.equalTo(titleLabel.snp.bottom).offset(8); $0.leading.trailing.equalTo(titleLabel) }
        progressIndicator.snp.makeConstraints { $0.top.equalTo(detailLabel.snp.bottom).offset(16); $0.leading.equalTo(titleLabel); $0.trailing.equalTo(cancelButton.snp.leading).offset(-16); $0.centerY.equalTo(cancelButton) }
        cancelButton.snp.makeConstraints { $0.trailing.equalTo(titleLabel); $0.top.equalTo(detailLabel.snp.bottom).offset(12); $0.width.equalTo(74) }
    }

    func markCancelling() {
        cancelButton.isEnabled = false
        cancelButton.title = "正在取消…"
        detailLabel.stringValue = "正在停止 SVN 进程并清理临时文件…"
    }

    @objc private func cancel() {
        markCancelling()
        onCancel?()
    }
}
