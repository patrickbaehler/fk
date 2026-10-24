import Foundation

enum SmartValueKind {
    case text
    case number
    case set
    case none
}

enum SmartOperator: String, Codable, CaseIterable, Identifiable {
    case contains
    case notContains
    case equals
    case beginsWith
    case atLeast
    case atMost
    case isTrue
    case isFalse

    var id: Self { self }

    func label(for field: SmartField) -> String {
        switch (field, self) {
        case (.inSet, .isTrue): return "ist enthalten in"
        case (.inSet, .isFalse): return "ist nicht enthalten in"
        case (.active, .isTrue): return "ist aktiv"
        case (.active, .isFalse): return "ist inaktiv"
        case (.favorite, .isTrue): return "ist Favorit"
        case (.favorite, .isFalse): return "ist kein Favorit"
        case (.importedDaysAgo, .atMost): return "vor höchstens"
        case (.importedDaysAgo, .atLeast): return "vor mindestens"
        default: break
        }
        switch self {
        case .contains: return "enthält"
        case .notContains: return "enthält nicht"
        case .equals: return "ist"
        case .beginsWith: return "beginnt mit"
        case .atLeast: return "mindestens"
        case .atMost: return "höchstens"
        case .isTrue: return "ja"
        case .isFalse: return "nein"
        }
    }
}

enum SmartField: String, Codable, CaseIterable, Identifiable {
    case name
    case family
    case style
    case postScriptName
    case foundry
    case format
    case tag
    case rating
    case active
    case favorite
    case importedDaysAgo
    case inSet

    var id: Self { self }

    var label: String {
        switch self {
        case .name: return "Name"
        case .family: return "Familie"
        case .style: return "Stil"
        case .postScriptName: return "PostScript-Name"
        case .foundry: return "Hersteller"
        case .format: return "Format"
        case .tag: return "Tag"
        case .rating: return "Bewertung"
        case .active: return "Status"
        case .favorite: return "Favorit"
        case .importedDaysAgo: return "Importiert"
        case .inSet: return "Set"
        }
    }

    var operators: [SmartOperator] {
        switch valueKind {
        case .text: return [.contains, .notContains, .equals, .beginsWith]
        case .number:
            return self == .importedDaysAgo ? [.atMost, .atLeast] : [.atLeast, .atMost, .equals]
        case .set, .none: return [.isTrue, .isFalse]
        }
    }

    var valueKind: SmartValueKind {
        switch self {
        case .name, .family, .style, .postScriptName, .foundry, .format, .tag: return .text
        case .rating, .importedDaysAgo: return .number
        case .inSet: return .set
        case .active, .favorite: return .none
        }
    }

    /// Text after the value field, e.g. "Tagen" for the import age.
    var unit: String? {
        switch self {
        case .importedDaysAgo: return "Tagen"
        case .rating: return "Sterne"
        default: return nil
        }
    }
}

struct SmartRule: Identifiable, Codable, Hashable {
    var id = UUID()
    var field: SmartField = .name
    var op: SmartOperator = .contains
    var value: String = ""
}

/// A set whose contents follow from rules.
struct SmartSet: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var matchAll = true
    var rules: [SmartRule] = [SmartRule()]

    /// Set IDs that rules refer to; their members must be supplied to `matches`.
    var referencedSetIDs: Set<UUID> {
        Set(rules.filter { $0.field == .inSet }.compactMap { UUID(uuidString: $0.value) })
    }

    func matches(_ record: FontRecord, now: Date, setMembers: [UUID: Set<UUID>]) -> Bool {
        let usable = rules.filter { $0.isComplete }
        guard !usable.isEmpty else { return false }
        if matchAll {
            return usable.allSatisfy { $0.matches(record, now: now, setMembers: setMembers) }
        }
        return usable.contains { $0.matches(record, now: now, setMembers: setMembers) }
    }
}

extension SmartRule {
    /// A rule without a value is ignored instead of matching everything.
    var isComplete: Bool {
        switch field.valueKind {
        case .none: return true
        case .text: return !value.trimmingCharacters(in: .whitespaces).isEmpty
        case .number: return Int(value.trimmingCharacters(in: .whitespaces)) != nil
        case .set: return UUID(uuidString: value) != nil
        }
    }

    func matches(_ record: FontRecord, now: Date, setMembers: [UUID: Set<UUID>]) -> Bool {
        switch field.valueKind {
        case .text:
            let candidates: [String]
            switch field {
            case .name: candidates = [record.fullName]
            case .family: candidates = [record.familyName]
            case .style: candidates = [record.styleName]
            case .postScriptName: candidates = [record.postScriptName]
            case .foundry: candidates = [record.foundryText]
            case .format: candidates = [record.format]
            case .tag: candidates = record.tags
            default: candidates = []
            }
            let wanted = value.trimmingCharacters(in: .whitespaces)
            let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            switch op {
            case .contains: return candidates.contains { $0.range(of: wanted, options: options) != nil }
            case .notContains: return !candidates.contains { $0.range(of: wanted, options: options) != nil }
            case .equals: return candidates.contains { $0.compare(wanted, options: options) == .orderedSame }
            case .beginsWith: return candidates.contains { $0.range(of: wanted, options: options.union(.anchored)) != nil }
            default: return false
            }
        case .number:
            guard let number = Int(value.trimmingCharacters(in: .whitespaces)) else { return false }
            let actual: Int
            if field == .importedDaysAgo {
                actual = Int(now.timeIntervalSince(record.importedAt) / 86_400)
            } else {
                actual = record.rating
            }
            switch op {
            case .atLeast: return actual >= number
            case .atMost: return actual <= number
            case .equals: return actual == number
            default: return false
            }
        case .set:
            guard let setID = UUID(uuidString: value) else { return false }
            let contained = setMembers[setID]?.contains(record.id) ?? false
            return op == .isTrue ? contained : !contained
        case .none:
            let flag = field == .active ? record.activation.isActive : record.isFavorite
            return op == .isTrue ? flag : !flag
        }
    }
}
