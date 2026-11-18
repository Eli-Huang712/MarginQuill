import AppKit
import SwiftUI

struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.clipsToBounds = true

        let editor = NSTextView(usingTextLayoutManager: false)
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.autoresizingMask = [.width]
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = NSSize(width: 10, height: 14)
        editor.backgroundColor = .textBackgroundColor
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.smartInsertDeleteEnabled = false
        editor.setAccessibilityLabel(L("Markdown 源码编辑区"))

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        editor.defaultParagraphStyle = paragraph
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.textColor = .textColor

        editor.delegate = context.coordinator
        scroll.documentView = editor
        scroll.hasVerticalRuler = true
        scroll.verticalRulerView = LineNumberRuler(scroll: scroll, editor: editor)
        scroll.rulersVisible = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView else { return }
        editor.isEditable = isEditable
        context.coordinator.text = $text
        if editor.string != text {
            editor.string = text
            (scroll.verticalRulerView as? LineNumberRuler)?.updateLines()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>?

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            (editor.enclosingScrollView?.verticalRulerView as? LineNumberRuler)?.updateLines()
            text?.wrappedValue = editor.string
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            editor.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }
    }
}

private final class LineNumberRuler: NSRulerView {
    private let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private var lineStarts = [0]
    override var isFlipped: Bool { true }

    init(scroll: NSScrollView, editor: NSTextView) {
        super.init(scrollView: scroll, orientation: .verticalRuler)
        clientView = editor
        ruleThickness = 36
        clipsToBounds = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrollDidMove),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }

    required init(coder: NSCoder) { fatalError("LineNumberRuler is created by MarkdownEditor") }

    @objc private func scrollDidMove() { needsDisplay = true }

    func updateLines() {
        guard let editor = clientView as? NSTextView else { return }
        let source = editor.string as NSString
        var starts = [0]
        var cursor = 0
        while cursor < source.length {
            var end = 0
            var contentsEnd = 0
            source.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: cursor, length: 0))
            if contentsEnd < end { starts.append(end) }
            cursor = end
        }
        lineStarts = starts
        let digits = String(repeating: "9", count: String(starts.count).count)
        let width = max(36, ceil((digits as NSString).size(withAttributes: [.font: numberFont]).width) + 20)
        if ruleThickness != width { ruleThickness = width }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = dirtyRect.intersection(bounds)
        NSColor.controlBackgroundColor.setFill()
        rect.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()
        guard let editor = clientView as? NSTextView, let layout = editor.layoutManager,
              let container = editor.textContainer else { return }

        let origin = editor.textContainerOrigin
        let visible = editor.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let first = glyphs.location < layout.numberOfGlyphs
            ? lineIndex(at: layout.characterIndexForGlyph(at: glyphs.location)) : lineStarts.count - 1
        let selected = lineIndex(at: editor.selectedRange().location)
        let textLength = (editor.string as NSString).length
        for line in first..<lineStarts.count {
            let start = lineStarts[line]
            let fragment = start < textLength
                ? layout.lineFragmentUsedRect(forGlyphAt: layout.glyphIndexForCharacter(at: start), effectiveRange: nil)
                : layout.extraLineFragmentRect
            let point = convert(NSPoint(x: 0, y: fragment.midY + origin.y), from: editor)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: numberFont,
                .foregroundColor: line == selected ? NSColor.labelColor : NSColor.secondaryLabelColor
            ]
            let label = String(line + 1) as NSString
            let size = label.size(withAttributes: attributes)
            let y = point.y - size.height / 2
            if y > bounds.maxY { break }
            if y + size.height < rect.minY || y > rect.maxY { continue }
            label.draw(at: NSPoint(x: bounds.maxX - size.width - 9, y: y), withAttributes: attributes)
        }
    }

    private func lineIndex(at location: Int) -> Int {
        var low = 0
        var high = lineStarts.count
        while low < high {
            let mid = (low + high) / 2
            if lineStarts[mid] <= location { low = mid + 1 } else { high = mid }
        }
        return max(0, low - 1)
    }
}
