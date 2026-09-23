import AppKit
import SwiftUI

@main
struct JaysonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Jayson") {
            MainWindow()
                .background(WindowConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .defaultSize(width: 1320, height: 820)
        .commands { AppCommands() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // When launched as a bare executable (`swift run`) there is no bundle; behave like an app anyway.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Debug aid: JAYSON_APPEARANCE=dark|light forces an appearance for screenshots/tests.
        switch ProcessInfo.processInfo.environment["JAYSON_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Applies the flat window chrome: transparent title bar with our own header underneath it.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = false
            window.backgroundColor = NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hex: 0x171718) : .white
            }
            window.toolbar = nil
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Menu commands

struct AppCommands: Commands {
    @FocusedValue(\.workspace) private var workspace
    @FocusedValue(\.document) private var document

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Document") { workspace?.newDocument(select: true) }
                .keyboardShortcut("n", modifiers: .command)
            Button("New Document from Clipboard") { workspace?.newDocumentFromPasteboard() }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Button("Open…") { workspace?.openDocumentFromFile() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Open from URL…") {
                guard let workspace else { return }
                let doc = workspace.newDocument(select: true)
                doc.urlPrompt = .json
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("Close Document") {
                guard let workspace else { return }
                if workspace.documents.count > 1 {
                    workspace.closeSelectedDocument()
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut("w", modifiers: .command)
            Divider()
            Button("Save As…") { document?.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Paste and Format") { document?.pasteAndFormat() }
                .keyboardShortcut("v", modifiers: [.command, .shift, .option])
            Button("Copy Formatted JSON") { document?.copyFormatted() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Copy Minified JSON") { document?.copyMinified() }
                .keyboardShortcut("c", modifiers: [.command, .shift, .option])
        }

        CommandGroup(after: .textEditing) {
            Divider()
            Button("Find in JSON") { workspace?.focusSidebarSearch(mode: .text) }
                .keyboardShortcut("f", modifiers: .command)
            Button("Query with JSONPath") { workspace?.focusSidebarSearch(mode: .jsonPath) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Find Next") { document?.nextHit() }
                .keyboardShortcut("g", modifiers: .command)
            Button("Find Previous") { document?.previousHit() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
        }

        CommandMenu("JSON") {
            Button("Format") { document?.format() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Minify") { document?.minify() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Clean Up") { document?.clean() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Button("Sort Keys") { document?.sortKeysNow() }
            Divider()
            Button("Expand All") { document?.expandAll() }
                .keyboardShortcut("e", modifiers: [.command, .option])
            Button("Collapse All") { document?.collapseAll() }
                .keyboardShortcut("e", modifiers: [.command, .option, .shift])
            Divider()
            Button("Load Sample JSON") { document?.replaceSource(with: SampleData.json, actionName: "Load Sample") }
        }

        CommandMenu("Schema") {
            Button("Infer Schema from JSON") { document?.inferSchema() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("New Blank Schema") { document?.newBlankSchema() }
            Divider()
            Button("Open Schema File…") { document?.openSchemaFile() }
            Button("Load Schema from URL…") { document?.urlPrompt = .schema }
            Button("Save Schema As…") { document?.saveAs(schema: true) }
            Divider()
            Button("Validate Now") { document?.validateNow() }
                .keyboardShortcut("r", modifiers: .command)
            Button("Format Schema") { document?.formatSchema() }
        }

        CommandMenu("Pipeline") {
            Button("New Pipeline") { workspace?.newPipeline() }
            Button("Import Pipeline…") { workspace?.importPipeline() }
            Divider()
            Button("Run Pipeline") { document?.runPipelineNow() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(document?.pipeline == nil)
            Button("Output as New Document") {
                guard let workspace, let document, let output = document.pipelineRun?.output else { return }
                let newDoc = workspace.newDocument(text: document.formatted(output), select: true)
                newDoc.customTitle = "\(document.pipeline?.name ?? "Pipeline") → \(document.title)"
            }
            .keyboardShortcut("n", modifiers: [.command, .option, .shift])
            .disabled(document?.pipelineRun?.output == nil)
            Button("Replace Document with Output") { document?.replaceDocumentWithPipelineOutput() }
                .disabled(document?.pipelineRun?.output == nil)
            Button("Save Output As…") { document?.savePipelineOutput() }
                .disabled(document?.pipelineRun?.output == nil)
            Divider()
            Button("Export Pipeline…") {
                guard let workspace, let pipeline = document?.pipeline else { return }
                workspace.exportPipeline(pipeline)
            }
            .disabled(document?.pipeline == nil)
            Button("Detach Pipeline") {
                guard let workspace, let document else { return }
                workspace.detachPipeline(from: document)
            }
            .disabled(document?.pipeline == nil)
        }

        CommandGroup(after: .sidebar) {
            Button(workspace?.isSidebarVisible == true ? "Hide Sidebar" : "Show Sidebar") { workspace?.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.command, .control])
            Button(workspace?.isSchemaPanelVisible == true ? "Hide Schema Panel" : "Show Schema Panel") { workspace?.toggleSchemaPanel() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button(workspace?.isPipelinePanelVisible == true ? "Hide Pipeline Panel" : "Show Pipeline Panel") { workspace?.togglePipelinePanel() }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Divider()
            Button("Source Only") { workspace?.viewMode = .source }.keyboardShortcut("1", modifiers: .command)
            Button("Split") { workspace?.viewMode = .split }.keyboardShortcut("2", modifiers: .command)
            Button("Tree Only") { workspace?.viewMode = .tree }.keyboardShortcut("3", modifiers: .command)
            Divider()
            Button("Next Document") { workspace?.selectNextDocument(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Document") { workspace?.selectNextDocument(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
        }
    }
}
