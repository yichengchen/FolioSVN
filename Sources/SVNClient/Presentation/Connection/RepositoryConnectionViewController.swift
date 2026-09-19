import AppKit
import SnapKit

struct RepositoryProfileDraft: Sendable {
    let displayName: String
    let url: URL
    let username: String
    let password: String
    let certificatePolicy: RepositoryProfile.CertificatePolicy
    let startPath: String

    var startURL: URL {
        startPath.split(separator: "/").reduce(url) { partialURL, component in
            partialURL.appendingPathComponent(String(component), isDirectory: true)
        }
    }

    var requestOptions: SVNRequestOptions {
        let credentials = username.isEmpty && password.isEmpty
            ? nil
            : SVNCredentials(username: username, password: password)
        return SVNRequestOptions(
            credentials: credentials,
            certificateTrustPolicy: certificatePolicy.svnPolicy
        )
    }
}

@MainActor
final class RepositoryConnectionViewController: NSViewController {
    var onCancel: (() -> Void)?
    var onTest: ((RepositoryProfileDraft) async throws -> Void)?
    var onSave: ((RepositoryProfileDraft) async throws -> Void)?

    private let nameField = NSTextField(string: "")
    private let urlField = NSTextField(string: "")
    private let usernameField = NSTextField(string: "")
    private let passwordField = NSSecureTextField(string: "")
    private let certificatePopup = NSPopUpButton()
    private let startPathField = NSTextField(string: "")
    private let warningLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private let testButton = NSButton(title: "测试连接", target: nil, action: nil)
    private let saveButton = NSButton(title: "保存并连接", target: nil, action: nil)
    private let existingProfile: RepositoryProfile?
    private let existingPassword: String?
    private var operationTask: Task<Void, Never>?
    private var operationID: UUID?

    init(profile: RepositoryProfile? = nil, password: String? = nil) {
        existingProfile = profile
        existingPassword = password
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 470))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureControls()
        configureLayout()
        populateExistingProfile()
        updateCertificateWarning()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nameField)
    }

    private func configureControls() {
        nameField.placeholderString = "例如：公司文档"
        urlField.placeholderString = "https://svn.example.com/repos/company"
        usernameField.placeholderString = "SVN 用户名"
        passwordField.placeholderString = "密码将安全保存到 macOS Keychain"
        startPathField.placeholderString = "可选，例如：技术部/共享资料"

        certificatePopup.addItems(withTitles: [
            "严格验证证书（推荐）",
            "允许自签名或未知 CA 证书",
            "允许所有证书错误（高风险）"
        ])
        certificatePopup.target = self
        certificatePopup.action = #selector(certificatePolicyChanged)

        warningLabel.textColor = .systemOrange
        warningLabel.font = .systemFont(ofSize: 12)
        statusLabel.isHidden = true

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false

        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        testButton.target = self
        testButton.action = #selector(testConnection)
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        if existingProfile != nil {
            saveButton.title = "保存更改"
        }
    }

    private func configureLayout() {
        let titleLabel = NSTextField(labelWithString: existingProfile == nil ? "添加 SVN 服务器" : "编辑 SVN 服务器")
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        let descriptionLabel = NSTextField(
            wrappingLabelWithString: "服务器配置保存在本机；密码只存入 macOS Keychain，不写入数据库或日志。"
        )
        descriptionLabel.textColor = .secondaryLabelColor

        let formRows: [(String, NSView)] = [
            ("服务器名称", nameField),
            ("SVN 地址", urlField),
            ("用户名", usernameField),
            ("密码", passwordField),
            ("默认起始路径", startPathField),
            ("HTTPS 证书", certificatePopup)
        ]
        let grid = NSGridView(views: formRows.map { label, control in
            let labelField = NSTextField(labelWithString: label)
            labelField.alignment = .right
            return [labelField, control]
        })
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        // Keep the form anchored to the dialog's content margins. Without an
        // explicit width, NSGridView lets the label column absorb spare space,
        // which pushes every input control unnecessarily far to the right.
        grid.column(at: 0).width = 120
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill

        for subview in [titleLabel, descriptionLabel, grid, warningLabel, statusLabel, progressIndicator, cancelButton, testButton, saveButton] {
            view.addSubview(subview)
        }

        titleLabel.snp.makeConstraints { $0.top.leading.trailing.equalToSuperview().inset(24) }
        descriptionLabel.snp.makeConstraints {
            $0.top.equalTo(titleLabel.snp.bottom).offset(8)
            $0.leading.trailing.equalToSuperview().inset(24)
        }
        grid.snp.makeConstraints {
            $0.top.equalTo(descriptionLabel.snp.bottom).offset(20)
            $0.leading.trailing.equalToSuperview().inset(24)
        }
        warningLabel.snp.makeConstraints {
            $0.top.equalTo(grid.snp.bottom).offset(12)
            $0.leading.equalToSuperview().inset(156)
            $0.trailing.equalToSuperview().inset(24)
        }
        statusLabel.snp.makeConstraints {
            $0.top.equalTo(warningLabel.snp.bottom).offset(8)
            $0.leading.equalTo(warningLabel)
            $0.trailing.equalToSuperview().inset(24)
        }
        saveButton.snp.makeConstraints { $0.trailing.bottom.equalToSuperview().inset(24); $0.width.equalTo(110) }
        testButton.snp.makeConstraints { $0.trailing.equalTo(saveButton.snp.leading).offset(-8); $0.centerY.equalTo(saveButton) }
        cancelButton.snp.makeConstraints { $0.trailing.equalTo(testButton.snp.leading).offset(-8); $0.centerY.equalTo(saveButton) }
        progressIndicator.snp.makeConstraints { $0.trailing.equalTo(cancelButton.snp.leading).offset(-12); $0.centerY.equalTo(saveButton) }
    }

    private func populateExistingProfile() {
        guard let existingProfile else { return }
        nameField.stringValue = existingProfile.displayName
        urlField.stringValue = existingProfile.baseURL.absoluteString
        usernameField.stringValue = existingProfile.username
        passwordField.stringValue = existingPassword ?? ""
        startPathField.stringValue = existingProfile.startPath
        switch existingProfile.certificatePolicy {
        case .strict: certificatePopup.selectItem(at: 0)
        case .allowUnknownCertificateAuthority: certificatePopup.selectItem(at: 1)
        case .allowAllFailures: certificatePopup.selectItem(at: 2)
        }
    }

    @objc private func certificatePolicyChanged() {
        updateCertificateWarning()
    }

    @objc private func cancel() {
        if let operationTask {
            operationTask.cancel()
            cancelButton.isEnabled = false
            showStatus("正在取消连接…", color: .secondaryLabelColor)
            return
        }
        onCancel?()
    }

    @objc private func testConnection() {
        guard let draft = validatedDraft(), let onTest else { return }
        runAsync(action: onTest, draft: draft, successMessage: "连接成功，可以保存此服务器")
    }

    @objc private func save() {
        guard let draft = validatedDraft(), let onSave else { return }
        runAsync(action: onSave, draft: draft, successMessage: nil)
    }

    private func runAsync(
        action: @escaping (RepositoryProfileDraft) async throws -> Void,
        draft: RepositoryProfileDraft,
        successMessage: String?
    ) {
        operationTask?.cancel()
        let id = UUID()
        operationID = id
        setLoading(true)
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if operationID == id {
                    operationTask = nil
                    operationID = nil
                }
            }
            do {
                try await action(draft)
                try Task.checkCancellation()
                guard operationID == id else { return }
                if let successMessage {
                    showStatus(successMessage, color: .systemGreen)
                    setLoading(false)
                }
            } catch is CancellationError {
                guard operationID == id else { return }
                showStatus("连接已取消", color: .secondaryLabelColor)
                setLoading(false)
            } catch {
                guard operationID == id else { return }
                showStatus(error.localizedDescription, color: .systemRed)
                setLoading(false)
            }
        }
    }

    private func validatedDraft() -> RepositoryProfileDraft? {
        let displayName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty else {
            showStatus("请输入服务器名称", color: .systemRed)
            return nil
        }

        let value = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else {
            showStatus("请输入有效的 SVN 地址", color: .systemRed)
            return nil
        }
        guard url.user == nil, url.password == nil else {
            showStatus("SVN 地址不能包含用户名或密码，请使用下方凭据字段", color: .systemRed)
            return nil
        }
        let supportedSchemes = ["file", "http", "https", "svn", "svn+ssh"]
        guard supportedSchemes.contains(scheme), scheme == "file" || url.host?.isEmpty == false else {
            showStatus("支持 https://、svn://、svn+ssh:// 和 file:// 地址", color: .systemRed)
            return nil
        }

        let rawStartPath = startPathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let startComponents = rawStartPath.split(separator: "/", omittingEmptySubsequences: true)
        guard !startComponents.contains(where: { $0 == "." || $0 == ".." }) else {
            showStatus("默认起始路径不能包含“.”或“..”", color: .systemRed)
            return nil
        }

        return RepositoryProfileDraft(
            displayName: displayName,
            url: url,
            username: usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            password: passwordField.stringValue,
            certificatePolicy: selectedCertificatePolicy,
            startPath: startComponents.joined(separator: "/")
        )
    }

    private var selectedCertificatePolicy: RepositoryProfile.CertificatePolicy {
        switch certificatePopup.indexOfSelectedItem {
        case 1: .allowUnknownCertificateAuthority
        case 2: .allowAllFailures
        default: .strict
        }
    }

    private func updateCertificateWarning() {
        switch selectedCertificatePolicy {
        case .strict:
            warningLabel.stringValue = ""
            warningLabel.isHidden = true
        case .allowUnknownCertificateAuthority:
            warningLabel.stringValue = "仅对当前服务器接受自签名或无法验证颁发机构的证书。请确认这是可信的内网服务器。"
            warningLabel.isHidden = false
        case .allowAllFailures:
            warningLabel.stringValue = "高风险：还会忽略主机名不匹配、证书过期和尚未生效等错误，仅用于你完全信任的隔离网络。"
            warningLabel.isHidden = false
        }
    }

    private func setLoading(_ isLoading: Bool) {
        for control in [nameField, urlField, usernameField, passwordField, startPathField, certificatePopup] {
            control.isEnabled = !isLoading
        }
        cancelButton.isEnabled = true
        cancelButton.title = isLoading ? "取消连接" : "取消"
        testButton.isEnabled = !isLoading
        saveButton.isEnabled = !isLoading
        isLoading ? progressIndicator.startAnimation(nil) : progressIndicator.stopAnimation(nil)
        if isLoading {
            statusLabel.isHidden = true
        }
    }

    private func showStatus(_ message: String, color: NSColor) {
        statusLabel.stringValue = message
        statusLabel.textColor = color
        statusLabel.isHidden = false
    }
}
