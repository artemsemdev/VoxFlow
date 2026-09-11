import AppKit
import SwiftUI

enum TranscriptWordPicker {
    static func word(atUTF16Offset offset: Int, in text: String) -> String? {
        guard offset >= 0 && offset < text.utf16.count else { return nil }
        var match: String?
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, range, _, stop in
            if NSLocationInRange(offset, NSRange(range, in: text)) {
                match = word
                stop = true
            }
        }
        return match
    }
}

struct TranscriptWordView: NSViewRepresentable {
    let text: String
    let addToDictionary: @MainActor (String) -> Void

    func makeNSView(context: Context) -> ContextWordTextView {
        let view = ContextWordTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.setAccessibilityLabel("Inserted transcript")
        return view
    }

    func updateNSView(_ view: ContextWordTextView, context: Context) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5.2
        view.textStorage?.setAttributedString(NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor,
                         .paragraphStyle: paragraph]))
        view.addToDictionary = addToDictionary
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ContextWordTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, let textContainer = nsView.textContainer,
              let layoutManager = nsView.layoutManager else { return nil }
        textContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        return CGSize(width: width, height: ceil(layoutManager.usedRect(for: textContainer).height))
    }
}

final class ContextWordTextView: NSTextView {
    var addToDictionary: @MainActor (String) -> Void = { _ in }
    private var clickedWord: String?

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenu(at: convert(event.locationInWindow, from: nil), addingTo: super.menu(for: event) ?? NSMenu())
    }

    /// Kept separate from `menu(for:)` so geometry and menu routing can be tested without posting
    /// synthetic events into the app. Reading the clicked word never changes the current selection.
    func contextMenu(at point: NSPoint, addingTo menu: NSMenu) -> NSMenu {
        guard let word = word(at: point) else { return menu }
        clickedWord = word
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let item = NSMenuItem(title: "Add to Dictionary", action: #selector(addClickedWord), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    func word(at point: NSPoint) -> String? {
        guard let layoutManager, let textContainer else { return nil }
        let location = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: location, in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs,
              layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer).contains(location)
        else { return nil }
        return TranscriptWordPicker.word(atUTF16Offset: layoutManager.characterIndexForGlyph(at: glyph), in: string)
    }

    @objc func addClickedWord() {
        guard let clickedWord else { return }
        addToDictionary(clickedWord)
    }
}
