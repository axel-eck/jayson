import AppKit
import SwiftUI

/// A plain-text code editor backed by NSTextView with lightweight JSON syntax colouring,
/// undo, the system find bar, and no smart-quote/dash substitutions.
struct SourceEditor: NSViewRepresentable {
    enum Syntax { case json, javaScript }

    @Binding var text: String
    /// When `highlightTick` changes, `highlight` is selected and scrolled into view.
    var highlight: NSRange? = nil
    var highlightTick: Int = 0
    var wrapLines = false
    var isEditable = true
    var syntax: Syntax = .json

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        context.coordinator.textView = textView

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = Theme.editorFont
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isEditable = isEditable
        textView.typingAttributes = [.font: Theme.editorFont, .foregroundColor: NSColor.labelColor]

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        configureWrapping(textView: textView, scrollView: scrollView)

        context.coordinator.push(text, to: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let syntaxChanged = context.coordinator.parent.syntax != syntax
        context.coordinator.parent = self
        textView.isEditable = isEditable
        if text != context.coordinator.lastKnownText {
            context.coordinator.push(text, to: textView)
        } else if syntaxChanged {
            context.coordinator.highlightNow(textView)
        }
        if highlightTick != context.coordinator.lastHighlightTick {
            context.coordinator.lastHighlightTick = highlightTick
            if let highlight {
                let length = (textView.string as NSString).length
                let clamped = NSRange(location: min(highlight.location, max(length - 1, 0)), length: min(highlight.length, max(length - highlight.location, 0)))
                textView.setSelectedRange(clamped)
                textView.scrollRangeToVisible(clamped)
                textView.showFindIndicator(for: clamped)
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    private func configureWrapping(textView: NSTextView, scrollView: NSScrollView) {
        guard let container = textView.textContainer else { return }
        if wrapLines {
            scrollView.hasHorizontalScroller = false
            textView.isHorizontallyResizable = false
            container.widthTracksTextView = true
            container.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        } else {
            scrollView.hasHorizontalScroller = true
            textView.isHorizontallyResizable = true
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SourceEditor
        weak var textView: NSTextView?
        var lastKnownText = ""
        var lastHighlightTick = 0
        private var highlightWork: DispatchWorkItem?

        init(_ parent: SourceEditor) {
            self.parent = parent
        }

        func push(_ text: String, to textView: NSTextView) {
            lastKnownText = text
            let selection = textView.selectedRange()
            textView.string = text
            let length = (text as NSString).length
            if selection.location <= length {
                textView.setSelectedRange(NSRange(location: selection.location, length: 0))
            }
            highlightNow(textView)
            if selection.location == 0 {
                textView.scroll(.zero)
            }
        }

        func highlightNow(_ textView: NSTextView) {
            switch parent.syntax {
            case .json: JSONSyntaxHighlighter.apply(to: textView)
            case .javaScript: JavaScriptSyntaxHighlighter.apply(to: textView)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            lastKnownText = textView.string
            parent.text = textView.string
            scheduleHighlight()
        }

        private func scheduleHighlight() {
            highlightWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, let textView = self.textView else { return }
                self.highlightNow(textView)
            }
            highlightWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
    }
}

/// Regex-based token colouring. Skipped for very large documents to keep typing responsive.
enum JSONSyntaxHighlighter {
    static let maxLength = 400_000

    private static let regex: NSRegularExpression = {
        let pattern = #"("(?:[^"\\]|\\.)*")(\s*:)?|(-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b)|\b(true|false)\b|\b(null)\b|([{}\[\],:])"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    @MainActor
    static func apply(to textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: Theme.editorFont, .foregroundColor: NSColor.labelColor], range: full)
        if storage.length <= maxLength {
            let string = storage.string as NSString
            regex.enumerateMatches(in: storage.string, range: full) { match, _, _ in
                guard let match else { return }
                if match.range(at: 1).location != NSNotFound {
                    let isKey = match.range(at: 2).location != NSNotFound
                    storage.addAttribute(.foregroundColor, value: isKey ? Theme.key : Theme.string, range: match.range(at: 1))
                } else if match.range(at: 3).location != NSNotFound {
                    storage.addAttribute(.foregroundColor, value: Theme.number, range: match.range(at: 3))
                } else if match.range(at: 4).location != NSNotFound {
                    storage.addAttribute(.foregroundColor, value: Theme.keyword, range: match.range(at: 4))
                } else if match.range(at: 5).location != NSNotFound {
                    storage.addAttribute(.foregroundColor, value: Theme.null, range: match.range(at: 5))
                } else if match.range(at: 6).location != NSNotFound {
                    storage.addAttribute(.foregroundColor, value: Theme.punctuation, range: match.range(at: 6))
                }
            }
            _ = string
        }
        storage.endEditing()
    }
}

/// Token colouring for JavaScript/TypeScript step code: comments, strings, numbers, keywords.
enum JavaScriptSyntaxHighlighter {
    static let maxLength = 200_000

    private static let regex: NSRegularExpression = {
        let keywords = ["const", "let", "var", "function", "return", "if", "else", "for", "of", "in", "while", "do", "switch", "case", "break", "continue", "new", "typeof", "instanceof", "class", "extends", "this", "import", "export", "from", "async", "await", "throw", "try", "catch", "finally", "yield", "delete", "void", "as", "type", "interface", "enum", "declare", "readonly", "keyof", "satisfies", "true", "false", "null", "undefined", "NaN", "Infinity"]
        let pattern = #"(//[^\n]*|/\*[\s\S]*?\*/)|("(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|`(?:[^`\\]|\\.)*`)|(\b\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?n?\b|\b0[xX][0-9a-fA-F_]+\b)|\b("# + keywords.joined(separator: "|") + #")\b"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    @MainActor
    static func apply(to textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: Theme.editorFont, .foregroundColor: NSColor.labelColor], range: full)
        if storage.length <= maxLength {
            regex.enumerateMatches(in: storage.string, range: full) { match, _, _ in
                guard let match else { return }
                if match.range(at: 1).location != NSNotFound {
                    storage.addAttribute(.foregroundColor, value: Theme.null, range: match.range(at: 1))
                } else if match.range(at: 2).location != NSNotFound {
                    storage.addAttribute(.foregroundColor, value: Theme.string, range: match.range(at: 2))
                } else if match.range(at: 3).location != NSNotFound {
                    storage.addAttribute(.foregroundColor, value: Theme.number, range: match.range(at: 3))
                } else if match.range(at: 4).location != NSNotFound {
                    storage.addAttribute(.foregroundColor, value: Theme.keyword, range: match.range(at: 4))
                }
            }
        }
        storage.endEditing()
    }
}
