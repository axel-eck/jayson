import AppKit
import SwiftUI
import JaysonCore

/// Semantic colours for JSON tokens. All are system colours, so they adapt to light/dark
/// mode and the user's accent/contrast settings automatically.
enum Theme {
    static let key = NSColor.systemIndigo
    static let string = NSColor.systemRed
    static let number = NSColor.systemBlue
    static let keyword = NSColor.systemOrange   // true / false / null
    static let punctuation = NSColor.secondaryLabelColor

    static let editorFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    static let treeFont = Font.system(size: 12.5, design: .monospaced)

    static func color(for value: JSONValue) -> Color {
        switch value {
        case .string: return Color(nsColor: string)
        case .number: return Color(nsColor: number)
        case .bool, .null: return Color(nsColor: keyword)
        case .array, .object: return .secondary
        }
    }

    static var matchBackground: Color { Color.yellow.opacity(0.22) }
    static var currentMatchBackground: Color { Color.orange.opacity(0.38) }
    static var errorBackground: Color { Color.red.opacity(0.12) }
}
