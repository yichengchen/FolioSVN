import AppKit
import SnapKit

@MainActor
final class SettingsViewController: NSViewController {
    var onClearRecentItems: (() -> Void)?

    private let recentCountLabel = NSTextField(labelWithString: "正在读取…")

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let titleLabel = NSTextField(labelWithString: "最近访问")
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)

        let descriptionLabel = NSTextField(wrappingLabelWithString: "最近访问只保存在当前 Mac，不包含密码、文件内容或临时认证地址，最多保留 50 条。")
        descriptionLabel.textColor = .secondaryLabelColor

        let clearButton = NSButton(title: "清空最近访问…", target: self, action: #selector(clearRecentItems))
        clearButton.bezelStyle = .rounded

        view.addSubview(titleLabel)
        view.addSubview(descriptionLabel)
        view.addSubview(recentCountLabel)
        view.addSubview(clearButton)

        titleLabel.snp.makeConstraints {
            $0.top.leading.trailing.equalToSuperview().inset(24)
        }
        descriptionLabel.snp.makeConstraints {
            $0.top.equalTo(titleLabel.snp.bottom).offset(10)
            $0.leading.trailing.equalToSuperview().inset(24)
        }
        recentCountLabel.snp.makeConstraints {
            $0.top.equalTo(descriptionLabel.snp.bottom).offset(18)
            $0.leading.equalToSuperview().inset(24)
        }
        clearButton.snp.makeConstraints {
            $0.centerY.equalTo(recentCountLabel)
            $0.trailing.equalToSuperview().inset(24)
        }
    }

    func updateRecentCount(_ count: Int) {
        recentCountLabel.stringValue = "当前保存 \(count) 条记录"
    }

    @objc private func clearRecentItems() {
        onClearRecentItems?()
    }
}
