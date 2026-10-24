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
    // Added in version 0.5; optional so older libraries still load.
    /// CoreText weight, width and slant traits (-1 … 1).
    var weight: Double?
    var widthTrait: Double?
    var slant: Double?
    var isItalic: Bool?
    /// Variation axes; empty for static fonts, nil if not read yet.
    var axes: [VariationAxis]?
    /// Hidden records stay on disk and in the library but are not listed.
    var isHidden: Bool?
    var metadataVersion: Int?

    static let currentMetadataVersion = 2

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
        applyMetadata(from: face)
    }

    mutating func applyMetadata(from face: ScannedFace) {
        weight = face.weight
        widthTrait = face.width
        slant = face.slant
        isItalic = face.isItalic
        axes = face.axes
        metadataVersion = Self.currentMetadataVersion
    }

    var duplicateKey: String { "\(postScriptName)|\(version ?? "")" }
    var versionText: String { version ?? "" }
    var foundryText: String { foundry ?? "" }
    var isVariable: Bool { !(axes ?? []).isEmpty }
    var hidden: Bool { isHidden ?? false }

    /// Name shown for a face listed under its family.
    var styleDisplayName: String { styleName.isEmpty ? fullName : styleName }
}

/// One axis of a variable font, e.g. weight from 100 to 900.
struct VariationAxis: Codable, Hashable, Identifiable {
    var identifier: UInt32
    var tag: String
    var name: String
    var minValue: Double
    var maxValue: Double
    var defaultValue: Double

    var id: String { tag }

    var displayName: String {
        switch tag {
        case "wght": return "Gewicht"
        case "wdth": return "Breite"
        case "slnt": return "Neigung"
        case "ital": return "Kursiv"
        case "opsz": return "Optische Grösse"
        case "GRAD": return "Grad"
        default: return name.isEmpty ? tag : name
        }
    }

    var rangeText: String {
        "\(Self.format(minValue)) – \(Self.format(maxValue)), Standard \(Self.format(defaultValue))"
    }

    static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    static func tagString(_ identifier: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((identifier >> UInt32($0)) & 0xFF) }
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }), let text = String(bytes: bytes, encoding: .ascii) {
            return text
        }
        return String(identifier)
    }
}

/// Orders faces within a family: by width, weight, then upright before italic.
enum FaceOrder {
    static let styleWords: [(String, Double)] = [
        ("hairline", -0.9), ("thin", -0.8), ("extralight", -0.6), ("ultralight", -0.6),
        ("light", -0.4), ("book", -0.1), ("regular", 0), ("roman", 0), ("normal", 0),
        ("medium", 0.23), ("semibold", 0.3), ("demibold", 0.3), ("demi", 0.3),
        ("bold", 0.4), ("extrabold", 0.56), ("ultrabold", 0.56), ("heavy", 0.62),
        ("black", 0.62), ("ultra", 0.7),
    ]

    /// Weight from the stored trait, or guessed from the style name.
    static func weight(of record: FontRecord) -> Double {
        if let weight = record.weight { return weight }
        let style = record.styleName.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        // Longest matching word wins ("extrabold" before "bold").
        let match = styleWords.filter { style.contains($0.0) }.max { $0.0.count < $1.0.count }
        return match?.1 ?? 0
    }

    static func italic(_ record: FontRecord) -> Bool {
        if let italic = record.isItalic { return italic }
        let style = record.styleName.lowercased()
        return style.contains("italic") || style.contains("oblique") || style.contains("kursiv")
    }

    static func areInOrder(_ lhs: FontRecord, _ rhs: FontRecord) -> Bool {
        let lw = lhs.widthTrait ?? 0, rw = rhs.widthTrait ?? 0
        if abs(lw - rw) > 0.01 { return lw < rw }
        let lweight = weight(of: lhs), rweight = weight(of: rhs)
        if abs(lweight - rweight) > 0.01 { return lweight < rweight }
        let li = italic(lhs), ri = italic(rhs)
        if li != ri { return !li }
        return lhs.styleDisplayName.localizedStandardCompare(rhs.styleDisplayName) == .orderedAscending
    }
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
    var smartSets: [SmartSet]

    init(version: Int, fonts: [FontRecord], sets: [FontSet], smartSets: [SmartSet]) {
        self.version = version
        self.fonts = fonts
        self.sets = sets
        self.smartSets = smartSets
    }

    enum CodingKeys: String, CodingKey {
        case version, fonts, sets, smartSets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        fonts = try container.decodeIfPresent([FontRecord].self, forKey: .fonts) ?? []
        sets = try container.decodeIfPresent([FontSet].self, forKey: .sets) ?? []
        smartSets = try container.decodeIfPresent([SmartSet].self, forKey: .smartSets) ?? []
    }
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
    case hidden
    case conflicts
    case set(UUID)
    case smartSet(UUID)
}
