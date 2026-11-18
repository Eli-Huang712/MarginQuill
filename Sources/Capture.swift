import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class CaptureButton: NSButton, @preconcurrency NSServicesMenuRequestor {
    let workspace: Workspace

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(frame: .zero)
        title = "导入纸稿"
        image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        imagePosition = .imageLeading
        bezelStyle = .rounded
        controlSize = .large
        target = self
        action = #selector(showCaptureMenu)
        toolTip = "从 iPhone 或 iPad 拍摄、扫描，或导入本地文件"
        setAccessibilityLabel("导入纸稿")
    }

    required init?(coder: NSCoder) { nil }

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                returnType: NSPasteboard.PasteboardType?) -> Any? {
        if canReceive(returnType) {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func canReceive(_ type: NSPasteboard.PasteboardType?) -> Bool {
        guard !workspace.isWorking, let type else { return false }
        return NSImage.imageTypes.contains(type.rawValue) || type == .pdf || type == .fileURL
    }

    func readSelection(from pasteboard: NSPasteboard) -> Bool {
        if let data = pasteboard.data(forType: .pdf) {
            return workspace.load(data: data, name: "iPhone 扫描")
        }
        let types: [NSPasteboard.PasteboardType] = [
            .png, .init(UTType.jpeg.identifier), .init(UTType.heic.identifier), .tiff
        ]
        for type in types {
            if let data = pasteboard.data(forType: type) {
                return workspace.load(data: data, name: "iPhone 拍摄")
            }
        }
        if let url = (pasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first,
           let data = try? Data(contentsOf: url) {
            return workspace.load(data: data, name: "iPhone 导入")
        }
        if let image = NSImage(pasteboard: pasteboard), let data = image.tiffRepresentation {
            return workspace.load(data: data, name: "iPhone 拍摄")
        }
        return false
    }

    @objc private func showCaptureMenu() {
        guard let window, !workspace.isWorking else { return }
        window.makeFirstResponder(self)
        // AppKit adds the nearby-device commands to this contextual menu.
        let location = convert(NSPoint(x: 6, y: isFlipped ? bounds.maxY : bounds.minY), to: nil)
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: location,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: 1) else { return }

        let menu = NSMenu()
        let open = NSMenuItem(title: "导入本地文件…", action: #selector(chooseFile), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc func chooseFile() { workspace.chooseFile() }
}

final class CaptureWindow: NSWindow {
    weak var captureButton: CaptureButton?

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        if let captureButton, captureButton.canReceive(returnType) {
            return captureButton
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }
}

struct PhoneCaptureControl: NSViewRepresentable {
    var button: CaptureButton
    var isEnabled: Bool

    func makeNSView(context: Context) -> CaptureButton { button }

    func updateNSView(_ view: CaptureButton, context: Context) {
        view.isEnabled = isEnabled
    }
}
