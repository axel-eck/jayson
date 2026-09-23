import Foundation

/// Everything needed to bring a window back the way the user left it.
struct SessionSnapshot: Codable {
    var version = 1
    var documents: [DocumentSnapshot] = []
    var selectedDocumentID: UUID?
    var schemas: [SchemaItem] = []
    var viewMode: String = ViewMode.split.rawValue
    var isSidebarVisible = true
    var isSchemaPanelVisible = false
}

struct DocumentSnapshot: Codable {
    var id: UUID
    var customTitle: String?
    var sourceURL: URL?
    var sourceText: String
    /// Library schema this document validates against, if any.
    var schemaItemID: UUID?
    /// Schema text kept on the document itself when it is not linked to a library item.
    var schemaText: String
    var schemaSource: String?
}

/// Reads and writes the session file in Application Support.
///
/// `JAYSON_SESSION_PATH` overrides the file location (debug aid for screenshots and tests);
/// pointing it at a path that does not exist yields a fresh first launch.
enum SessionStore {
    private static let overridePath: String? = {
        let value = ProcessInfo.processInfo.environment["JAYSON_SESSION_PATH"] ?? ""
        return value.isEmpty ? nil : value
    }()

    static let fileURL: URL = {
        if let overridePath { return URL(fileURLWithPath: overridePath) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Jayson", isDirectory: true).appendingPathComponent("session.json")
    }()

    private static let hasLaunchedKey = "hasLaunchedBefore"
    private static let legacyLibraryKey = "schemaLibrary"

    /// True until a session has been saved once. An existing (pre-session) schema library also
    /// counts as a previous launch so upgrading users do not get the sample back.
    static var isFirstLaunch: Bool {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return false }
        if overridePath != nil { return true }
        let defaults = UserDefaults.standard
        return !defaults.bool(forKey: hasLaunchedKey) && defaults.object(forKey: legacyLibraryKey) == nil
    }

    static func load() -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    /// Schemas saved by versions that kept the library in UserDefaults.
    static func loadLegacySchemas() -> [SchemaItem] {
        guard let data = UserDefaults.standard.data(forKey: legacyLibraryKey),
              let items = try? JSONDecoder().decode([SchemaItem].self, from: data) else { return [] }
        return items
    }

    static func save(_ snapshot: SessionSnapshot) {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
            UserDefaults.standard.set(true, forKey: hasLaunchedKey)
        } catch {
            NSLog("Jayson: could not save session to \(fileURL.path): \(error.localizedDescription)")
        }
    }
}
