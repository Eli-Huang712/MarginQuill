import AppKit
import Combine
import SwiftUI

@MainActor
final class PaperNotesApp: NSObject, NSApplicationDelegate, NSToolbarDelegate, NSToolbarItemValidation {
    private static let historyToolbar = NSToolbarItem.Identifier("PaperNotes.History")
    private static let newToolbar = NSToolbarItem.Identifier("PaperNotes.New")
    private static let settingsToolbar = NSToolbarItem.Identifier("PaperNotes.Settings")

    private let workspace = Workspace()
    private var capture: CaptureButton!
    private var window: NSWindow!
    private var historyItem: NSToolbarItem?
    private var subscriptions = Set<AnyCancellable>()

    func applicationWillFinishLaunching(_ notification: Notification) {
        capture = CaptureButton(workspace: workspace)
        let root = NSMenu()
        let appMenu = NSMenuItem()
        let fileMenu = NSMenuItem()
        let editMenu = NSMenuItem()
        root.addItem(appMenu)
        root.addItem(fileMenu)
        root.addItem(editMenu)

        let appActions = NSMenu(title: "纸笺")
        appActions.addItem(NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ","))
        appActions.items.last?.target = self
        appActions.addItem(.separator())
        appActions.addItem(withTitle: "退出纸笺", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.submenu = appActions

        let fileActions = NSMenu(title: "文件")
        fileActions.addItem(withTitle: "新建", action: #selector(newNote), keyEquivalent: "n").target = self
        let device = NSMenuItem(title: "从 iPhone 或 iPad 导入", action: nil, keyEquivalent: "")
        device.identifier = NSMenuItem.importFromDeviceIdentifier
        fileActions.addItem(device)
        fileActions.addItem(withTitle: "导入文件…", action: #selector(CaptureButton.chooseFile), keyEquivalent: "o")
            .target = capture
        fileActions.addItem(withTitle: "导出 Markdown…", action: #selector(exportMarkdown), keyEquivalent: "s")
            .target = self
        fileMenu.submenu = fileActions

        let editActions = NSMenu(title: "编辑")
        editActions.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editActions.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editActions.addItem(.separator())
        editActions.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editActions.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editActions.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editActions.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.submenu = editActions
        NSApp.mainMenu = root
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let view = WorkspaceView(workspace: workspace, capture: capture)
        let controller = NSHostingController(rootView: view)
        let captureWindow = CaptureWindow(contentViewController: controller)
        captureWindow.captureButton = capture
        window = captureWindow
        window.title = "纸笺"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        let toolbar = NSToolbar(identifier: "PaperNotes.Toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        bindWindow(to: toolbar)
        window.contentMinSize = NSSize(width: 995, height: 530)
        window.setContentSize(NSSize(width: 1270, height: 742))
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(capture)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        workspace.finishSession() ? .terminateNow : .terminateCancel
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        workspace.load(urls: urls)
    }

    private func bindWindow(to toolbar: NSToolbar) {
        workspace.$record.map { record -> String in
            guard let record, !record.markdown.isEmpty else { return "纸笺" }
            return record.title
        }
        .removeDuplicates()
        .sink { [weak self] title in self?.window?.title = title }
        .store(in: &subscriptions)

        workspace.$showingHistory.sink { [weak self] visible in
            self?.updateHistoryItem(visible)
        }.store(in: &subscriptions)

        workspace.$isPreparing.combineLatest(workspace.$isRecognizing).sink { [weak toolbar] _, _ in
            DispatchQueue.main.async { toolbar?.validateVisibleItems() }
        }.store(in: &subscriptions)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.historyToolbar, Self.newToolbar, Self.settingsToolbar]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.target = self
        item.isNavigational = true
        switch identifier {
        case Self.historyToolbar:
            item.label = "历史记录"
            item.action = #selector(toggleHistory)
            historyItem = item
            updateHistoryItem(workspace.showingHistory)
        case Self.newToolbar:
            item.label = "新建"
            item.toolTip = "新建纸稿"
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "新建")
            item.action = #selector(newNote)
        case Self.settingsToolbar:
            item.label = "API 设置"
            item.toolTip = "OpenAI API 设置"
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "API 设置")
            item.action = #selector(showSettings)
        default:
            return nil
        }
        return item
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case Self.newToolbar: return !workspace.isWorking
        case Self.settingsToolbar: return !workspace.isRecognizing
        default: return true
        }
    }

    private func updateHistoryItem(_ visible: Bool) {
        historyItem?.toolTip = visible ? "收起历史记录侧栏" : "展开历史记录侧栏"
        let symbol = visible ? "sidebar.left" : "clock"
        historyItem?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "历史记录")
    }

    @objc private func newNote() { workspace.newNote() }
    @objc private func toggleHistory() { workspace.showingHistory.toggle() }
    @objc private func showSettings() { workspace.showingSettings = true }
    @objc private func exportMarkdown() { workspace.export() }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = PaperNotesApp()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
