import SwiftUI
import CryptoKit

/// One line in the font list: a family (with its faces as children) or a
/// single face.
struct FontRow: Identifiable {
    let id: UUID
    let record: FontRecord?
    let faces: [FontRecord]
    let isChild: Bool
    var children: [FontRow]?

    // Sort keys
    var name: String
    var family: String
    var style: String
    var format: String
    var rating: Int

    var isFamily: Bool { record == nil }
    var isVariable: Bool { faces.contains(where: \.isVariable) }

    static func face(_ record: FontRecord, isChild: Bool) -> FontRow {
        FontRow(
            id: record.id, record: record, faces: [record], isChild: isChild, children: nil,
            name: isChild ? record.styleDisplayName : record.fullName,
            family: record.familyName,
            style: record.styleName,
            format: FormatPreference.label(record),
            rating: record.rating
        )
    }

    static func family(_ name: String, faces: [FontRecord]) -> FontRow {
        let ordered = faces.sorted(by: FaceOrder.areInOrder)
        let formats = Set(faces.map { FormatPreference.label($0) }).sorted()
        return FontRow(
            id: familyID(name), record: nil, faces: ordered, isChild: false,
            children: ordered.map { face($0, isChild: true) },
            name: name,
            family: name,
            style: "\(faces.count) Schnitte",
            format: formats.joined(separator: ", "),
            rating: faces.map(\.rating).max() ?? 0
        )
    }

    /// Stable ID for a family row, derived from the family name.
    static func familyID(_ name: String) -> UUID {
        let digest = Insecure.MD5.hash(data: Data(("family:" + name).utf8))
        return digest.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
    }

    /// The face that represents the family, e.g. for the name in its own font.
    var representative: FontRecord? {
        faces.min { lhs, rhs in
            let li = FaceOrder.italic(lhs), ri = FaceOrder.italic(rhs)
            if li != ri { return !li }
            return abs(FaceOrder.weight(of: lhs)) < abs(FaceOrder.weight(of: rhs))
        }
    }
}

struct FontListView: View {
    @EnvironmentObject private var store: LibraryStore
    let source: SidebarItem
    let search: String
    /// Selected faces; a selected family stands for all its listed faces.
    @Binding var selection: Set<FontRecord.ID>

    @State private var tableSelection = Set<UUID>()
    @State private var sortOrder = [KeyPathComparator(\FontRow.name)]
    @State private var pendingRemoval: Set<UUID> = []
    @AppStorage("wysiwygNames") private var wysiwygNames = false
    @AppStorage("groupByFamily") private var groupByFamily = true

    private var records: [FontRecord] {
        store.records(in: source, matching: search)
    }

    private func makeRows(_ records: [FontRecord]) -> [FontRow] {
        guard groupByFamily else {
            return records.map { FontRow.face($0, isChild: false) }.sorted(using: sortOrder)
        }
        let groups = Dictionary(grouping: records, by: \.familyName)
        return groups.map { name, faces in
            faces.count == 1 ? FontRow.face(faces[0], isChild: false) : FontRow.family(name, faces: faces)
        }
        .sorted(using: sortOrder)
    }

    /// Turns table IDs (families and faces) into face IDs.
    private func expand(_ ids: Set<UUID>) -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        var result = Set<UUID>()
        for row in makeRows(records) {
            if ids.contains(row.id) { result.formUnion(row.faces.map(\.id)) }
            for child in row.children ?? [] where ids.contains(child.id) {
                result.insert(child.id)
            }
        }
        return result
    }

    var body: some View {
        let records = self.records
        let rows = makeRows(records)
        VStack(spacing: 0) {
            if store.fonts.isEmpty {
                emptyLibrary
            } else {
                table(rows)
            }
            Divider()
            statusBar(records: records, rows: rows)
        }
        .dropDestination(for: URL.self) { urls, _ in
            store.importFonts(from: urls)
            return true
        }
        .onChange(of: tableSelection) { _, newValue in
            selection = expand(newValue)
        }
        .onChange(of: selection) { _, newValue in
            if newValue.isEmpty && !tableSelection.isEmpty { tableSelection = [] }
        }
        .confirmationDialog(
            "\(pendingRemoval.count) Schriften aus der Bibliothek entfernen?",
            isPresented: Binding(get: { !pendingRemoval.isEmpty }, set: { if !$0 { pendingRemoval = [] } })
        ) {
            Button("Entfernen", role: .destructive) {
                store.remove(pendingRemoval)
                selection.subtract(pendingRemoval)
                pendingRemoval = []
            }
        } message: {
            Text("Schriften werden deaktiviert. Dateien, die Fontwerk in seinen eigenen Ordner kopiert hat, kommen in den Papierkorb.")
        }
    }

    private func table(_ rows: [FontRow]) -> some View {
        Table(rows, children: \.children, selection: $tableSelection, sortOrder: $sortOrder) {
            TableColumn("") { row in
                RowStatusIcon(row: row)
            }
            .width(22)

            TableColumn("Name", value: \.name) { row in
                RowNameCell(row: row, inOwnFont: wysiwygNames)
            }
            .width(min: 180, ideal: 280)

            TableColumn("Familie", value: \.family)
                .width(min: 100, ideal: 150)

            TableColumn("Stil", value: \.style)
                .width(min: 60, ideal: 100)

            TableColumn("Format", value: \.format)
                .width(min: 70, ideal: 110)

            TableColumn("Bewertung", value: \.rating) { row in
                Text(row.isFamily ? "" : String(repeating: "★", count: row.rating))
                    .foregroundStyle(.orange)
            }
            .width(min: 60, ideal: 80)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            contextMenu(for: expand(ids))
        } primaryAction: { ids in
            store.toggleActivation(expand(ids))
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<FontRecord.ID>) -> some View {
        if !ids.isEmpty {
            if source == .hidden {
                Button("Wieder einblenden") {
                    store.unhide(ids)
                    selection.subtract(ids)
                }
                Divider()
            } else {
                Button("Aktivieren bis Abmelden") { store.activate(ids, scope: .session) }
                Button("Dauerhaft aktivieren") { store.activate(ids, scope: .persistent) }
                Button("Deaktivieren") { store.deactivate(ids) }
                Divider()
                Menu("Zu Set hinzufügen") {
                    let targets = store.regularSetsByPath
                    ForEach(targets) { set in
                        Button(store.displayPath(of: set)) { store.add(ids, toSet: set.id) }
                    }
                    if !targets.isEmpty { Divider() }
                    Button("Neues Set aus Auswahl") { store.createSet(named: "Neues Set", with: ids) }
                }
                if case .set(let setID) = source, store.set(withID: setID)?.isFolder == false {
                    Button("Aus diesem Set entfernen") { store.remove(ids, fromSet: setID) }
                }
                Menu("Bewertung") {
                    ForEach(0...5, id: \.self) { stars in
                        Button(stars == 0 ? "Keine" : String(repeating: "★", count: stars)) {
                            store.setRating(ids, rating: stars)
                        }
                    }
                }
                let allFavorite = store.records(withIDs: ids).allSatisfy(\.isFavorite)
                Button(allFavorite ? "Aus Favoriten entfernen" : "Zu Favoriten") {
                    store.setFavorite(ids, !allFavorite)
                }
                Divider()
                Button("Musterblatt drucken …") {
                    let records = store.records(withIDs: ids).sorted(by: FaceOrder.areInOrder)
                    let sample = UserDefaults.standard.string(forKey: "previewText") ?? ""
                    SampleSheetPrinter.print(records, sampleText: sample)
                }
                Button("Im Finder zeigen") { store.showInFinder(ids) }
                Divider()
                Button("Ausblenden") {
                    store.hide(ids)
                    selection.subtract(ids)
                }
            }
            Button("Aus Bibliothek entfernen …", role: .destructive) { pendingRemoval = ids }
        }
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("Noch keine Schriften", systemImage: "textformat")
        } description: {
            Text("Importiere Schriftdateien oder ganze Ordner, oder zieh sie hierher.")
        } actions: {
            Button("Schriften importieren …") { store.presentImportPanel() }
            Button("FontExplorer-Bibliothek übernehmen …") { store.showFEXImport = true }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusBar(records: [FontRecord], rows: [FontRow]) -> some View {
        HStack(spacing: 8) {
            Toggle("Nach Familien gruppieren", isOn: $groupByFamily)
                .toggleStyle(.checkbox)
                .fixedSize()
            Divider().frame(height: 12)
            if let progress = store.importProgress {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .frame(width: 120)
                Text("Import \(progress.done) von \(progress.total)")
            } else if let message = store.message {
                Text(message)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(message)
            }
            Spacer()
            let active = records.filter { $0.activation.isActive }.count
            let families = Set(records.map(\.familyName)).count
            Text("\(families) Familien · \(records.count) Schriften · \(active) aktiv")
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}

struct StatusIcon: View {
    let record: FontRecord

    var body: some View {
        Group {
            if record.isMissing {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            } else {
                switch record.activation {
                case .inactive:
                    Image(systemName: "circle").foregroundStyle(.tertiary)
                case .session:
                    Image(systemName: "circle.fill").foregroundStyle(.green)
                case .persistent:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .external:
                    Image(systemName: "checkmark.circle").foregroundStyle(.blue)
                }
            }
        }
        .help(record.isMissing ? "Datei fehlt" : record.activation.label)
    }
}

/// Status of a row; for a family the combined status of its faces.
struct RowStatusIcon: View {
    let row: FontRow

    var body: some View {
        if let record = row.record {
            StatusIcon(record: record)
        } else {
            let active = row.faces.filter { $0.activation.isActive }.count
            Group {
                if row.faces.contains(where: \.isMissing) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                } else if active == 0 {
                    Image(systemName: "circle").foregroundStyle(.tertiary)
                } else if active == row.faces.count {
                    let allPermanent = row.faces.allSatisfy { $0.activation == .persistent }
                    Image(systemName: allPermanent ? "checkmark.circle.fill" : "circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "circle.lefthalf.filled").foregroundStyle(.green)
                }
            }
            .help("\(active) von \(row.faces.count) Schnitten aktiv")
        }
    }
}

struct RowNameCell: View {
    let row: FontRow
    let inOwnFont: Bool

    var body: some View {
        HStack(spacing: 6) {
            nameText
                .lineLimit(1)
            if row.isVariable {
                VariableBadge()
            }
        }
    }

    @ViewBuilder
    private var nameText: some View {
        let shown = inOwnFont ? (row.record ?? row.representative) : nil
        if let shown, let ctFont = FontFaceCache.shared.font(for: shown, size: 14) {
            Text(row.name).font(Font(ctFont))
        } else if row.isFamily {
            Text(row.name).fontWeight(.semibold)
        } else {
            Text(row.name)
        }
    }
}

struct VariableBadge: View {
    var body: some View {
        Text("Variabel")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.purple.opacity(0.18)))
            .foregroundStyle(.purple)
            .help("Variable Font: Gewicht, Breite oder weitere Eigenschaften sind stufenlos einstellbar.")
    }
}
