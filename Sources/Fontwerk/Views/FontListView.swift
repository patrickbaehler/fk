import SwiftUI

struct FontListView: View {
    @EnvironmentObject private var store: LibraryStore
    let source: SidebarItem
    let search: String
    @Binding var selection: Set<FontRecord.ID>

    @State private var sortOrder = [
        KeyPathComparator(\FontRecord.familyName),
        KeyPathComparator(\FontRecord.styleName),
    ]
    @State private var pendingRemoval: Set<UUID> = []
    @AppStorage("wysiwygNames") private var wysiwygNames = false

    private var rows: [FontRecord] {
        store.records(in: source, matching: search).sorted(using: sortOrder)
    }

    var body: some View {
        let rows = self.rows
        VStack(spacing: 0) {
            if store.fonts.isEmpty {
                emptyLibrary
            } else {
                table(rows)
            }
            Divider()
            statusBar(rows)
        }
        .dropDestination(for: URL.self) { urls, _ in
            store.importFonts(from: urls)
            return true
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

    private func table(_ rows: [FontRecord]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("") { record in
                StatusIcon(record: record)
            }
            .width(20)

            TableColumn("Name", value: \.fullName) { record in
                NameCell(record: record, inOwnFont: wysiwygNames)
            }
            .width(min: 160, ideal: 240)

            TableColumn("Familie", value: \.familyName)
                .width(min: 100, ideal: 160)

            TableColumn("Stil", value: \.styleName)
                .width(min: 60, ideal: 100)

            TableColumn("Format", value: \.format)
                .width(min: 70, ideal: 100)

            TableColumn("Bewertung", value: \.rating) { record in
                Text(String(repeating: "★", count: record.rating))
                    .foregroundStyle(.orange)
            }
            .width(min: 60, ideal: 80)
        }
        .contextMenu(forSelectionType: FontRecord.ID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            store.toggleActivation(ids)
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<FontRecord.ID>) -> some View {
        if !ids.isEmpty {
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
            Button("Im Finder zeigen") { store.showInFinder(ids) }
            Divider()
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

    private func statusBar(_ rows: [FontRecord]) -> some View {
        HStack(spacing: 8) {
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
            let active = rows.filter { $0.activation.isActive }.count
            Text("\(rows.count) Schriften · \(active) aktiv")
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

struct NameCell: View {
    let record: FontRecord
    let inOwnFont: Bool

    var body: some View {
        if inOwnFont, let ctFont = FontFaceCache.shared.font(for: record, size: 14) {
            Text(record.fullName).font(Font(ctFont))
        } else {
            Text(record.fullName)
        }
    }
}
