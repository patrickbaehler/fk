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

extension LibraryStore {
    private func recordsByPostScriptName() -> [String: [FontRecord]] {
        var result: [String: [FontRecord]] = [:]
        for record in fonts where !record.postScriptName.isEmpty {
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
                records: records.sorted { VersionComparison.isNewer($0.versionText, than: $1.versionText) },
                externalLocations: outside,
                suggestedKeepID: distinctFiles > 1 ? Self.suggestedKeep(among: records)?.id : nil
            ))
        }
        return groups.sorted { $0.postScriptName.localizedStandardCompare($1.postScriptName) == .orderedAscending }
    }

    /// Newest version first, then more glyphs, then the one already
    /// active, then the earliest import.
    static func suggestedKeep(among records: [FontRecord]) -> FontRecord? {
        records.max { lhs, rhs in
            if VersionComparison.isNewer(rhs.versionText, than: lhs.versionText) { return true }
            if VersionComparison.isNewer(lhs.versionText, than: rhs.versionText) { return false }
            if lhs.glyphCount != rhs.glyphCount { return lhs.glyphCount < rhs.glyphCount }
            if lhs.activation.isActive != rhs.activation.isActive { return !lhs.activation.isActive }
            return lhs.importedAt > rhs.importedAt
        }
    }

    /// For every group with library duplicates: keep the suggested
    /// record, remove the others.
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
