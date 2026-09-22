import AppKit
import SwiftUI
import JaysonCore

/// Token colours for the editor and tree. A low-saturation palette that resolves per
/// appearance, so it stays readable in both light and dark mode.
enum Theme {
    static let key = dynamic(light: 0x1F2328, dark: 0xE4E4E7)          // primary text, medium weight
    static let string = dynamic(light: 0x0E7C71, dark: 0x6FD4C4)       // teal
    static let number = dynamic(light: 0xB25E09, dark: 0xF5B84B)       // amber
    static let keyword = dynamic(light: 0x7C3AED, dark: 0xC4B5FD)      // violet: true / false
    static let null = dynamic(light: 0x8B8F98, dark: 0x8B8F98)         // gray, italic
    static let punctuation = dynamic(light: 0x9AA0A6, dark: 0x6B7280)  // braces, brackets, colons, commas
    static let index = dynamic(light: 0x8B8F98, dark: 0x8B8F98)        // array indices in the tree

    static let editorFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    static let treeFont = Font.system(size: 12.5, design: .monospaced)

    static func color(for value: JSONValue) -> Color {
        switch value {
        case .string: return Color(nsColor: string)
        case .number: return Color(nsColor: number)
        case .bool: return Color(nsColor: keyword)
        case .null: return Color(nsColor: null)
        case .array, .object: return Color(nsColor: punctuation)
        }
    }

    static var matchBackground: Color { Color.yellow.opacity(0.20) }
    static var currentMatchBackground: Color { Color.orange.opacity(0.32) }
    static var errorBackground: Color { Color.red.opacity(0.10) }

    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        }
    }
}
