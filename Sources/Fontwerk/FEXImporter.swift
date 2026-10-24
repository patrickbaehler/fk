import Foundation
import SQLite3

// Reads a FontExplorer X Pro library ("FontExplorer X.fexdb", SQLite).
//
// Relevant tables, as written by FontExplorer X Pro 7:
//   containers      one row per font file: containerID, path, format,
//                   isSystemFont, activate, addedDate (seconds since 2001),
//                   bookmarkData
//   fonts           one row per face: containerID, psName, rating,
//                   fontClassificationIds and tagging* (space-separated IDs)
//   sourceItems     sidebar entries: serialID, type, title, parentSerialID
//                   type 7 = set, 8 = folder, 31 = application set
//   setContainers   set membership: serialID, containerID
//   applicationSetPaths   serialID, path of the program
//   smartGroupRules rules of smart sets (not imported)

enum FEXImportError: LocalizedError {
    case cannotOpen(String)
    case notAFontExplorerLibrary
    case query(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let reason): return "Die Datenbank konnte nicht geöffnet werden: \(reason)"
        case .notAFontExplorerLibrary: return "Die Datei ist keine FontExplorer-X-Bibliothek."
        case .query(let reason): return "Die Datenbank konnte nicht gelesen werden: \(reason)"
        }
    }
}

struct FEXContainer {
    let id: Int64
    let path: String
    let bookmark: Data?
    let format: Int
    let isSystemFont: Bool
    let isActive: Bool
    let addedDate: Date?
}

struct FEXFaceInfo {
    var rating: Int
    var tags: [String]
}

struct FEXSourceItem {
    static let typeSet = 7
    static let typeFolder = 8
    static let typeApplicationSet = 31

    let serialID: Int64
    let type: Int
    let title: String
    let parentSerialID: Int64
    var applicationPath: String?
    var containerIDs: [Int64]
}

struct FEXLibrary {
    var version: String
    var containers: [FEXContainer]
    /// containerID → PostScript name → rating and tags
    var faceInfo: [Int64: [String: FEXFaceInfo]]
    var items: [FEXSourceItem]
    var smartSetCount: Int
}

struct FEXImportPlan {
    let library: FEXLibrary
    let sourceURL: URL
    var importable: [FEXContainer] = []
    var resolvedURLs: [Int64: URL] = [:]
    var skippedSystem = 0
    var skippedAdobe = 0
    var missing: [FEXContainer] = []
    var activeCount = 0

    var folderCount: Int { library.items.filter { $0.type == FEXSourceItem.typeFolder }.count }
    var setCount: Int { library.items.filter { $0.type == FEXSourceItem.typeSet }.count }
    var applicationSetCount: Int { library.items.filter { $0.type == FEXSourceItem.typeApplicationSet }.count }
}

struct FEXImportOptions {
    var copyFiles: Bool
    var restoreActivation: Bool
    var importTags: Bool
}

enum FEXImporter {
    static var defaultDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Linotype/FontExplorer X/FontExplorer X.fexdb")
    }

    static let fontExplorerLibraryMarker = "/FontExplorer X/Font Library/"

    // MARK: Reading

    static func read(databaseAt url: URL) throws -> FEXLibrary {
        // Work on a copy: the original stays untouched and FontExplorer may
        // still hold it open.
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("fontwerk-fex-\(UUID().uuidString).sqlite")
        do {
            try fm.copyItem(at: url, to: temp)
        } catch {
            throw FEXImportError.cannotOpen(error.localizedDescription)
        }
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: url.path + suffix)
            if fm.fileExists(atPath: side.path) {
                try? fm.copyItem(at: side, to: URL(fileURLWithPath: temp.path + suffix))
            }
        }
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? fm.removeItem(atPath: temp.path + suffix)
            }
        }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(temp.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = handle else {
            let reason = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unbekannter Fehler"
            sqlite3_close(handle)
            throw FEXImportError.cannotOpen(reason)
        }
        defer { sqlite3_close(db) }

        let reader = SQLiteReader(db: db)
        guard reader.hasTable("containers"), reader.hasTable("fonts"), reader.hasTable("sourceItems") else {
            throw FEXImportError.notAFontExplorerLibrary
        }

        var version = ""
        if reader.hasTable("versionInfo") {
            try reader.query("SELECT shortVersion FROM versionInfo LIMIT 1") { version = reader.text($0, 0) }
        }

        // Containers
        let containerColumns = reader.columns(of: "containers")
        func column(_ name: String) -> String { containerColumns.contains(name) ? name : "NULL" }
        var containers: [FEXContainer] = []
        try reader.query("""
            SELECT containerID, path, \(column("bookmarkData")), format, \(column("isSystemFont")),
                   \(column("activate")), \(column("addedDate"))
            FROM containers ORDER BY containerID
            """) { row in
            let added = reader.int(row, 6)
            containers.append(FEXContainer(
                id: reader.int(row, 0),
                path: reader.text(row, 1),
                bookmark: reader.blob(row, 2),
                format: Int(reader.int(row, 3)),
                isSystemFont: reader.int(row, 4) != 0,
                isActive: reader.int(row, 5) != 0,
                addedDate: added > 0 ? Date(timeIntervalSinceReferenceDate: TimeInterval(added)) : nil
            ))
        }

        // Names for classification and tag IDs
        var classifications: [String: String] = [:]
        if reader.hasTable("fontClassifications") {
            let hasGerman = reader.columns(of: "fontClassifications").contains("title_de")
            try reader.query("SELECT fontClassificationID, title, \(hasGerman ? "title_de" : "''") FROM fontClassifications") { row in
                let german = reader.text(row, 2)
                classifications[String(reader.int(row, 0))] = german.isEmpty ? reader.text(row, 1) : german
            }
        }
        func names(from table: String, idColumn: String) throws -> [String: String] {
            var result: [String: String] = [:]
            guard reader.hasTable(table) else { return result }
            try reader.query("SELECT \(idColumn), name FROM \(table)") { row in
                result[String(reader.int(row, 0))] = reader.text(row, 1)
            }
            return result
        }
        let usages = try names(from: "tagging_usages", idColumn: "usageID")
        let themes = try names(from: "tagging_themes", idColumn: "themeID")
        let categories = try names(from: "tagging_categories", idColumn: "categoryID")

        // Faces
        let fontColumns = reader.columns(of: "fonts")
        func fontColumn(_ name: String) -> String { fontColumns.contains(name) ? name : "''" }
        var faceInfo: [Int64: [String: FEXFaceInfo]] = [:]
        try reader.query("""
            SELECT containerID, psName, \(fontColumns.contains("rating") ? "rating" : "0"),
                   \(fontColumn("fontClassificationIds")), \(fontColumn("taggingUsages")),
                   \(fontColumn("taggingThemes")), \(fontColumn("taggingCategories"))
            FROM fonts
            """) { row in
            var tags: [String] = []
            func addNames(_ ids: String, _ lookup: [String: String]) {
                for id in ids.split(separator: " ") {
                    if let name = lookup[String(id)], !name.isEmpty, !tags.contains(name) { tags.append(name) }
                }
            }
            addNames(reader.text(row, 3), classifications)
            addNames(reader.text(row, 4), usages)
            addNames(reader.text(row, 5), themes)
            addNames(reader.text(row, 6), categories)
            let info = FEXFaceInfo(rating: Int(reader.int(row, 2)), tags: tags)
            faceInfo[reader.int(row, 0), default: [:]][reader.text(row, 1)] = info
        }

        // Sidebar items and their contents
        var members: [Int64: [Int64]] = [:]
        if reader.hasTable("setContainers") {
            try reader.query("SELECT serialID, containerID FROM setContainers") { row in
                members[reader.int(row, 0), default: []].append(reader.int(row, 1))
            }
        }
        var applicationPaths: [Int64: String] = [:]
        if reader.hasTable("applicationSetPaths") {
            try reader.query("SELECT serialID, path FROM applicationSetPaths") { row in
                applicationPaths[reader.int(row, 0)] = reader.text(row, 1)
            }
        }
        var smartIDs = Set<Int64>()
        if reader.hasTable("smartGroupRules") {
            try reader.query("SELECT DISTINCT serialID FROM smartGroupRules") { smartIDs.insert(reader.int($0, 0)) }
        }
        var items: [FEXSourceItem] = []
        try reader.query("SELECT serialID, type, title, parentSerialID FROM sourceItems") { row in
            let serial = reader.int(row, 0)
            let type = Int(reader.int(row, 1))
            guard [FEXSourceItem.typeSet, FEXSourceItem.typeFolder, FEXSourceItem.typeApplicationSet].contains(type),
                  !smartIDs.contains(serial) else { return }
            items.append(FEXSourceItem(
                serialID: serial,
                type: type,
                title: reader.text(row, 2),
                parentSerialID: reader.int(row, 3),
                applicationPath: applicationPaths[serial],
                containerIDs: members[serial] ?? []
            ))
        }

        return FEXLibrary(version: version, containers: containers, faceInfo: faceInfo,
                          items: items, smartSetCount: smartIDs.count)
    }

    // MARK: Planning

    /// Decides which files can be taken over. System fonts and Adobe Fonts
    /// stay with macOS and Creative Cloud.
    static func makePlan(for library: FEXLibrary, sourceURL: URL) -> FEXImportPlan {
        var plan = FEXImportPlan(library: library, sourceURL: sourceURL)
        let fm = FileManager.default
        for container in library.containers {
            if container.isSystemFont || container.path.hasPrefix("/System/") {
                plan.skippedSystem += 1
                continue
            }
            if container.path.contains("/Adobe/CoreSync/") {
                plan.skippedAdobe += 1
                continue
            }
            guard let url = resolve(container, fileManager: fm) else {
                plan.missing.append(container)
                continue
            }
            plan.importable.append(container)
            plan.resolvedURLs[container.id] = url
            if container.isActive { plan.activeCount += 1 }
        }
        return plan
    }

    private static func resolve(_ container: FEXContainer, fileManager fm: FileManager) -> URL? {
        if !container.path.isEmpty, fm.fileExists(atPath: container.path) {
            return URL(fileURLWithPath: container.path)
        }
        if let bookmark = container.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                  relativeTo: nil, bookmarkDataIsStale: &stale),
               fm.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }
}

/// Minimal helper around the SQLite C interface.
private struct SQLiteReader {
    let db: OpaquePointer

    func query(_ sql: String, _ row: (OpaquePointer) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw FEXImportError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW { row(statement); continue }
            if result == SQLITE_DONE { break }
            throw FEXImportError.query(String(cString: sqlite3_errmsg(db)))
        }
    }

    func hasTable(_ name: String) -> Bool {
        var found = false
        try? query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = '\(name)'") { _ in found = true }
        return found
    }

    func columns(of table: String) -> Set<String> {
        var result = Set<String>()
        try? query("PRAGMA table_info(\(table))") { result.insert(text($0, 1)) }
        return result
    }

    func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    func int(_ statement: OpaquePointer, _ index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    func blob(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard let pointer = sqlite3_column_blob(statement, index) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        return count > 0 ? Data(bytes: pointer, count: count) : nil
    }
}
