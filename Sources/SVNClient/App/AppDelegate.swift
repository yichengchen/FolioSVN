import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: MainCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        do {
            let coordinator = try MainCoordinator()
            self.coordinator = coordinator
            coordinator.start()
        } catch {
            let alert = NSAlert()
            alert.messageText = "\(AppBrand.displayName) 无法启动"
            alert.informativeText = "无法初始化服务器配置：\(error.localizedDescription)"
            alert.alertStyle = .critical
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let activeTransferCount = coordinator?.activeTransferCount ?? 0
        guard activeTransferCount > 0 else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "仍有 \(activeTransferCount) 个传输任务正在进行"
        alert.informativeText = "现在退出会中断任务。下载中的临时文件会被清理；正在写入 SVN 的任务建议等待完成。"
        alert.addButton(withTitle: "继续等待")
        alert.addButton(withTitle: "仍然退出")
        alert.buttons.last?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: AppBrand.displayName)
        applicationMenu.addItem(
            withTitle: "关于 \(AppBrand.displayName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "隐藏 \(AppBrand.displayName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        applicationMenu.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        applicationMenu.addItem(withTitle: "显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "退出 \(AppBrand.displayName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(withTitle: "打开", action: Selector(("openSelectedItem")), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "下载…", action: Selector(("downloadSelectedItem")), keyEquivalent: "s")
        fileMenu.addItem(.separator())
        let newFolderItem = fileMenu.addItem(
            withTitle: "新建文件夹",
            action: Selector(("createFolderFromMenu")),
            keyEquivalent: "n"
        )
        newFolderItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: "上传…", action: Selector(("uploadFilesFromMenu")), keyEquivalent: "")
        for item in fileMenu.items { item.target = nil }
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        for item in editMenu.items { item.target = nil }
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "显示")
        viewMenu.addItem(withTitle: "刷新", action: Selector(("refreshRepositoryFromMenu")), keyEquivalent: "r")
        let quickLookItem = viewMenu.addItem(
            withTitle: "快速查看",
            action: Selector(("toggleQuickLook")),
            keyEquivalent: " "
        )
        quickLookItem.keyEquivalentModifierMask = []
        for item in viewMenu.items { item.target = nil }
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        NSApp.mainMenu = mainMenu
    }
}
