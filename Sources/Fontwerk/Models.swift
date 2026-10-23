import Foundation

/// How a font file is currently registered with macOS.
enum ActivationState: String, Codable, CaseIterable {
    case inactive
    /// Registered until the user logs out.
    case session
    /// Registered permanently (survives logout and restart).
    case persistent

    var label: String {
        switch self {
        case .inactive: return "Inaktiv"
        case .session: return "Aktiv bis Abmelden"
        case .persistent: return "Dauerhaft aktiv"
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

/// A user-defined collection of fonts.
struct FontSet: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var fontIDs: [UUID]
}

/// What is written to library.json.
struct LibraryData: Codable {
    var version: Int
    var fonts: [FontRecord]
    var sets: [FontSet]
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
