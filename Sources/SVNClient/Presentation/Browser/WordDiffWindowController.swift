import AppKit
import WebKit
import UniformTypeIdentifiers

@MainActor
final class WordDiffWindowController: NSWindowController, NSWindowDelegate {
    private let result: WordDiffResult

    init(result: WordDiffResult, title: String) {
        self.result = result
        let webView = WKWebView(frame: .zero)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(title) — \(result.revisionCount) 条修订"
        let contentView = NSView()
        let exportButton = NSButton(title: "导出修订 DOCX…", target: nil, action: nil)
        contentView.addSubview(webView)
        contentView.addSubview(exportButton)
        webView.translatesAutoresizingMaskIntoConstraints = false
        exportButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: contentView.topAnchor),
            webView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: exportButton.topAnchor, constant: -12),
            exportButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            exportButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
        window.contentView = contentView
        window.minSize = NSSize(width: 600, height: 400)
        super.init(window: window)
        exportButton.target = self
        exportButton.action = #selector(exportDocument)
        window.delegate = self
        webView.loadFileURL(result.htmlURL, allowingReadAccessTo: result.directoryURL)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) {
        try? FileManager.default.removeItem(at: result.directoryURL)
    }

    @objc private func exportDocument() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "compared.docx"
        panel.allowedContentTypes = [UTType(filenameExtension: "docx")!]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let destination = panel.url else { return }
            do {
                // Atomic write preserves an existing destination if writing fails.
                try Data(contentsOf: self.result.documentURL).write(to: destination, options: .atomic)
            } catch {
                let alert = NSAlert(error: error)
                alert.beginSheetModal(for: window)
            }
        }
    }
}
