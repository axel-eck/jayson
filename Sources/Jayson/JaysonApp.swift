import AppKit
import SwiftUI

@main
struct JaysonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Jayson") {
            ContentView()
        }
        .defaultSize(width: 1240, height: 780)
        .commands { AppCommands() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // When launched as a bare executable (`swift run`) there is no bundle; behave like an app anyway.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - Focused model plumbing

struct AppModelFocusedKey: FocusedValueKey {
    typealias Value = AppModel
}

extension FocusedValues {
    var appModel: AppModel? {
        get { self[AppModelFocusedKey.self] }
        set { self[AppModelFocusedKey.self] = newValue }
    }
}

// MARK: - Menu commands

struct AppCommands: Commands {
    @FocusedValue(\.appModel) private var model

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open JSON…") { model?.openFile() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Open JSON from URL…") { model?.urlPrompt = .json }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("Save JSON As…") { model?.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Paste and Format") { model?.pasteAndFormat() }
                .keyboardShortcut("v", modifiers: [.command, .shift, .option])
            Button("Copy Formatted JSON") { model?.copyFormatted() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Copy Minified JSON") { model?.copyMinified() }
                .keyboardShortcut("c", modifiers: [.command, .shift, .option])
        }

        CommandGroup(after: .textEditing) {
            Divider()
            Button("Find in JSON") { model?.focusSearch(mode: .text) }
                .keyboardShortcut("f", modifiers: .command)
            Button("Query with JSONPath") { model?.focusSearch(mode: .jsonPath) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Find Next") { model?.nextHit() }
                .keyboardShortcut("g", modifiers: .command)
            Button("Find Previous") { model?.previousHit() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
        }

        CommandMenu("JSON") {
            Button("Format") { model?.format() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Minify") { model?.minify() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Clean Up") { model?.clean() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Button("Sort Keys") { model?.sortKeysNow() }
            Divider()
            Button("Expand All") { model?.expandAll() }
                .keyboardShortcut("e", modifiers: [.command, .option])
            Button("Collapse All") { model?.collapseAll() }
                .keyboardShortcut("e", modifiers: [.command, .option, .shift])
            Divider()
            Button("Load Sample JSON") { model?.replaceSource(with: SampleData.json, actionName: "Load Sample") }
        }

        CommandMenu("Schema") {
            Button("Infer Schema from JSON") { model?.inferSchema() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("New Blank Schema") { model?.newBlankSchema() }
            Divider()
            Button("Open Schema File…") { model?.openSchemaFile() }
            Button("Load Schema from URL…") { model?.urlPrompt = .schema }
            Button("Save Schema As…") { model?.saveAs(schema: true) }
            Divider()
            Button("Validate Now") { model?.validateNow() }
                .keyboardShortcut("r", modifiers: .command)
            Button("Format Schema") { model?.formatSchema() }
            Divider()
            Button(model?.showSchemaPanel == true ? "Hide Schema Panel" : "Show Schema Panel") {
                model?.showSchemaPanel.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }
}
