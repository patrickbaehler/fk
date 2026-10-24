import Foundation

/// How a font file is currently registered with macOS.
enum ActivationState: String, Codable, CaseIterable {
    case inactive
    /// Registered until the user logs out.
    case session
    /// Registered permanently (survives logout and restart).
    case persistent
    /// Available to apps, but not through Fontwerk, e.g. because the
    /// file lies in a macOS font folder.
    case external

    var label: String {
        switch self {
        case .inactive: return "Inaktiv"
        case .session: return "Aktiv bis Abmelden"
        case .persistent: return "Dauerhaft aktiv"
        case .external: return "Aktiv über macOS-Schriftordner"
        }
    }

    var isActive: Bool { self != .inactive }
}

/// One font face in the library. A collection file (.ttc/.otc/.dfont)
/// produces several records that share the same file.
struct FontRecord: Identifiable, Codable, Hashable {
    var id: UUID
    var fileURL: URL
    var postScriptName: String
    var fullName: String
    var familyName: String
    var styleName: String
    var format: String
    var version: String?
    var foundry: String?
    var glyphCount: Int
    var faceIndex: Int
    var fileSize: Int64
    var importedAt: Date
    var activation: ActivationState
    var rating: Int
    var isFavorite: Bool
    var tags: [String]
    var isMissing: Bool

    init(scanned face: ScannedFace, fileURL: URL) {
        id = UUID()
        self.fileURL = fileURL
        postScriptName = face.postScriptName
        fullName = face.fullName
        familyName = face.familyName
        styleName = face.styleName
        format = face.format
        version = face.version
        foundry = face.foundry
        glyphCount = face.glyphCount
        faceIndex = face.faceIndex
        fileSize = face.fileSize
        importedAt = Date()
        activation = .inactive
        rating = 0
        isFavorite = false
        tags = []
        isMissing = false
    }

    var duplicateKey: String { "\(postScriptName)|\(version ?? "")" }
    var versionText: String { version ?? "" }
    var foundryText: String { foundry ?? "" }
}

/// A user-defined collection of fonts, or a folder that groups sets.
/// A folder shows the fonts of every set inside it.
struct FontSet: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var fontIDs: [UUID]
    var parentID: UUID?
    var isFolder: Bool
    /// For sets that belong to a program (FontExplorer "Application Sets").
    var applicationPath: String?

    init(id: UUID = UUID(), name: String, fontIDs: [UUID] = [], parentID: UUID? = nil,
         isFolder: Bool = false, applicationPath: String? = nil) {
        self.id = id
        self.name = name
        self.fontIDs = fontIDs
        self.parentID = parentID
        self.isFolder = isFolder
        self.applicationPath = applicationPath
    }

    enum CodingKeys: String, CodingKey {
        case id, name, fontIDs, parentID, isFolder, applicationPath
    }

    // Libraries written by version 0.1 have no folder fields.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        fontIDs = try container.decodeIfPresent([UUID].self, forKey: .fontIDs) ?? []
        parentID = try container.decodeIfPresent(UUID.self, forKey: .parentID)
        isFolder = try container.decodeIfPresent(Bool.self, forKey: .isFolder) ?? false
        applicationPath = try container.decodeIfPresent(String.self, forKey: .applicationPath)
    }
}

/// A titled message shown as an alert.
struct InfoAlert: Identifiable {
    let id = UUID()
    var title: String
    var text: String
}

/// What is written to library.json.
struct LibraryData: Codable {
    var version: Int
    var fonts: [FontRecord]
    var sets: [FontSet]
}

/// Fonts that stayed available to apps after a deactivation, with the
/// files macOS still provides them from.
struct StillActiveReport: Identifiable {
    struct Entry {
        var fontName: String
        var locations: [URL]
    }
    let id = UUID()
    var entries: [Entry]

    var allLocations: [URL] {
        var seen = Set<URL>()
        return entries.flatMap(\.locations).filter { seen.insert($0).inserted }
    }

    var summary: String {
        let examples = entries.prefix(5).map { entry -> String in
            let places = entry.locations.prefix(2).map { url -> String in
                let folder = ActivationService.displayPath(url)
                return url.path.hasPrefix("/System/") ? "\(folder) (Systemschrift)" : folder
            }
            return "• \(entry.fontName): \(places.joined(separator: ", "))"
        }
        var text = "Diese Schriften stehen Apps weiterhin zur Verfügung, weil macOS sie aus einer anderen Datei oder einem Schriftordner lädt:\n\n"
        text += examples.joined(separator: "\n")
        if entries.count > 5 { text += "\n… und \(entries.count - 5) weitere" }
        text += "\n\nUm sie zu deaktivieren, entferne diese Dateien aus dem Ordner (Systemschriften lassen sich nicht deaktivieren). Bereits laufende Programme zeigen eine Schrift teils bis zum Neustart weiter an."
        return text
    }
}

struct ImportProgress: Equatable {
    var total: Int
    var done: Int
}

enum SidebarItem: Hashable {
    case all
    case active
    case inactive
    case favorites
    case recent
    case missing
    case set(UUID)
}
