import Foundation
import CoreText

/// Faces that share a PostScript name. Apps can only use one of them,
/// so having several active leads to wrong fonts in documents.
struct ConflictGroup: Identifiable {
    var id: String { postScriptName }
    let postScriptName: String
    /// Library records with this name, in different files.
    let records: [FontRecord]
    /// Files outside the library that macOS provides with this name.
    let externalLocations: [URL]
    /// Record Fontwerk suggests keeping when the library has duplicates.
    let suggestedKeepID: UUID?

    var hasLibraryDuplicates: Bool { Set(records.map(\.fileURL)).count > 1 }
}

enum VersionComparison {
    /// Numbers of the first version-like token, e.g. "Version 2.013;PS" → [2, 13].
    static func numbers(in text: String) -> [Int] {
        var result: [Int] = []
        var current = ""
        var started = false
        for character in text {
            if character.isNumber {
                current.append(character)
                started = true
            } else if character == "." && started {
                if let value = Int(current) { result.append(value) }
                current = ""
            } else if started {
                break
            }
        }
        if let value = Int(current) { result.append(value) }
        return result
    }

    static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        let a = numbers(in: lhs)
        let b = numbers(in: rhs)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}

enum ExternalFonts {
    /// PostScript name → files outside the library that macOS currently
    /// provides. Hidden system faces (names starting with ".") are left out.
    static func byPostScriptName(excludingPaths libraryPaths: Set<String>) -> [String: [URL]] {
        let collection = CTFontCollectionCreateFromAvailableFonts(nil)
        guard let descriptors = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] else {
            return [:]
        }
        var result: [String: [URL]] = [:]
        for descriptor in descriptors {
            guard let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String,
                  !name.hasPrefix("."),
                  let url = CTFontDescriptorCopyAttribute(descriptor, kCTFontURLAttribute) as? URL else { continue }
            let path = ActivationService.normalizedPath(url)
            guard !libraryPaths.contains(path) else { continue }
            if !(result[name]?.contains(url) ?? false) {
                result[name, default: []].append(url)
            }
        }
        return result
    }
}

/// Which file format to prefer when the same font exists several times:
/// OpenType (.otf) first, then TrueType; PostScript Type 1 and old Mac
/// suitcases last.
enum FormatPreference {
    static func rank(_ record: FontRecord) -> Int {
        let ext = record.fileURL.pathExtension.lowercased()
        if ["", "suit", "dfont", "bmap"].contains(ext) { return 5 }
        switch record.format {
        case "OpenType PS": return 0
        case "OpenType TT": return 1
        case "TrueType": return 2
        case "WOFF", "WOFF2": return 3
        case "PostScript": return 6
        case "Bitmap": return 7
        default:
            switch ext {
            case "otf": return 0
            case "ttf", "ttc": return 2
            case "pfb", "pfa": return 6
            default: return 4
            }
        }
    }

    static func label(_ record: FontRecord) -> String {
        switch rank(record) {
        case 0: return "OpenType"
        case 1, 2: return "TrueType"
        case 3: return "Webfont"
        case 5: return "Koffer"
        case 6: return "PostScript Type 1"
        default: return record.format
        }
    }
}

extension LibraryStore {
    private func recordsByPostScriptName() -> [String: [FontRecord]] {
        var result: [String: [FontRecord]] = [:]
        for record in fonts where !record.postScriptName.isEmpty && !record.hidden {
            result[record.postScriptName, default: []].append(record)
        }
        return result
    }

    var libraryDuplicateGroupCount: Int {
        recordsByPostScriptName().values.filter { Set($0.map(\.fileURL)).count > 1 }.count
    }

    func conflictGroups(external: [String: [URL]]) -> [ConflictGroup] {
        var groups: [ConflictGroup] = []
        for (name, records) in recordsByPostScriptName() {
            let distinctFiles = Set(records.map(\.fileURL)).count
            let outside = external[name] ?? []
            guard distinctFiles > 1 || !outside.isEmpty else { continue }
            groups.append(ConflictGroup(
                postScriptName: name,
                records: records.sorted { lhs, rhs in
                    let lr = FormatPreference.rank(lhs), rr = FormatPreference.rank(rhs)
                    if lr != rr { return lr < rr }
                    return VersionComparison.isNewer(lhs.versionText, than: rhs.versionText)
                },
                externalLocations: outside,
                suggestedKeepID: distinctFiles > 1 ? Self.suggestedKeep(among: records)?.id : nil
            ))
        }
        return groups.sorted { $0.postScriptName.localizedStandardCompare($1.postScriptName) == .orderedAscending }
    }

    /// Preferred format first (.otf, then TrueType), then the newest
    /// version, more glyphs, the one already active, the earliest import.
    static func suggestedKeep(among records: [FontRecord]) -> FontRecord? {
        records.max { lhs, rhs in
            let lr = FormatPreference.rank(lhs), rr = FormatPreference.rank(rhs)
            if lr != rr { return lr > rr }
            if VersionComparison.isNewer(rhs.versionText, than: lhs.versionText) { return true }
            if VersionComparison.isNewer(lhs.versionText, than: rhs.versionText) { return false }
            if lhs.glyphCount != rhs.glyphCount { return lhs.glyphCount < rhs.glyphCount }
            if lhs.activation.isActive != rhs.activation.isActive { return !lhs.activation.isActive }
            return lhs.importedAt > rhs.importedAt
        }
    }

    /// Number of files the automatic decisions would affect.
    func affectedCount(_ decisions: [(keep: UUID, remove: Set<UUID>)]) -> Int {
        decisions.reduce(0) { $0 + $1.remove.count }
    }

    /// For every group with library duplicates: keep the suggested
    /// record, remove (or hide) the others.
    func automaticConflictDecisions() -> [(keep: UUID, remove: Set<UUID>)] {
        conflictGroups(external: [:]).compactMap { group -> (keep: UUID, remove: Set<UUID>)? in
            guard group.hasLibraryDuplicates, let keep = group.suggestedKeepID else { return nil }
            let keepFile = group.records.first { $0.id == keep }?.fileURL
            let others = Set(group.records.filter { $0.id != keep && $0.fileURL != keepFile }.map(\.id))
            if others.isEmpty { return nil }
            return (keep: keep, remove: others)
        }
    }
}
