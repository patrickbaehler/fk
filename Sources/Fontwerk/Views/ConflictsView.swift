import SwiftUI
import AppKit

/// Lists faces that share a PostScript name, inside the library and with
/// fonts macOS provides from elsewhere.
struct ConflictsView: View {
    @EnvironmentObject private var store: LibraryStore
    @Binding var selection: Set<FontRecord.ID>

    @State private var external: [String: [URL]] = [:]
    @State private var checkingExternal = true
    @State private var confirmAutomatic = false
    @State private var confirmHide = false

    var body: some View {
        let groups = store.conflictGroups(external: external)
        let decisions = store.automaticConflictDecisions()
        VStack(spacing: 0) {
            header(groups: groups, decisions: decisions)
            Divider()
            if groups.isEmpty && !checkingExternal {
                ContentUnavailableView(
                    "Keine Konflikte",
                    systemImage: "checkmark.seal",
                    description: Text("Keine Schrift kommt mehrfach vor.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.records) { record in
                                ConflictRecordRow(record: record, isSuggested: record.id == group.suggestedKeepID)
                                    .tag(record.id)
                                    .contextMenu { menu(for: record, in: group) }
                            }
                            ForEach(group.externalLocations, id: \.self) { url in
                                ExternalLocationRow(url: url)
                            }
                        } header: {
                            ConflictHeader(group: group)
                        }
                    }
                }
            }
        }
        .task { await loadExternal() }
        .confirmationDialog(
            "Doppelte Schriften entfernen?",
            isPresented: $confirmAutomatic
        ) {
            Button("\(store.affectedCount(decisions)) Duplikate entfernen", role: .destructive) {
                store.resolveConflicts(decisions)
                selection.removeAll()
            }
        } message: {
            Text("Pro Schrift bleibt die empfohlene Fassung erhalten (OpenType vor TrueType, sonst die neueste Version). Sets, Bewertungen und Tags gehen auf sie über. Die übrigen Dateien in Fontwerks Ordner kommen in den Papierkorb.")
        }
        .confirmationDialog(
            "Nur die bevorzugte Fassung anzeigen?",
            isPresented: $confirmHide
        ) {
            Button("\(store.affectedCount(decisions)) Fassungen ausblenden") {
                store.hideConflicts(decisions.map { (keep: $0.keep, hide: $0.remove) })
                selection.removeAll()
            }
        } message: {
            Text("Pro Schrift bleibt die OpenType-Fassung sichtbar, ohne OpenType die TrueType-Fassung. PostScript-Type-1-Schriften, Koffer und ältere Versionen werden deaktiviert und ausgeblendet. Alle Dateien bleiben auf dem Computer; unter «Ausgeblendet» kannst du sie wieder einblenden.")
        }
    }

    private func header(groups: [ConflictGroup], decisions: [(keep: UUID, remove: Set<UUID>)]) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(groups.filter(\.hasLibraryDuplicates).count) Schriften mehrfach in der Bibliothek, \(groups.filter { !$0.externalLocations.isEmpty }.count) auch ausserhalb von Fontwerk")
                    .font(.callout)
                Text("Gleichnamige Schriften stören sich gegenseitig. Grün markiert ist die bevorzugte Fassung: OpenType vor TrueType, sonst die neueste Version.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if checkingExternal { ProgressView().controlSize(.small) }
            Menu("Automatisch bereinigen") {
                Button("Nur OpenType anzeigen, andere Fassungen ausblenden …") { confirmHide = true }
                Button("Duplikate aus der Bibliothek entfernen …") { confirmAutomatic = true }
            }
            .fixedSize()
            .disabled(decisions.isEmpty)
        }
        .padding(10)
    }

    @ViewBuilder
    private func menu(for record: FontRecord, in group: ConflictGroup) -> some View {
        if group.hasLibraryDuplicates {
            Button("Nur diese Fassung zeigen, andere ausblenden") {
                let others = Set(group.records.filter { $0.id != record.id && $0.fileURL != record.fileURL }.map(\.id))
                store.hideConflicts([(keep: record.id, hide: others)])
                selection.removeAll()
            }
            Button("Diese behalten, andere entfernen") {
                let others = Set(group.records.filter { $0.id != record.id && $0.fileURL != record.fileURL }.map(\.id))
                store.resolveConflicts([(keep: record.id, remove: others)])
                selection.removeAll()
            }
            Button("Diese aktivieren, andere deaktivieren") {
                let others = Set(group.records.filter { $0.id != record.id }.map(\.id))
                store.deactivate(others, verify: false)
                store.activate([record.id])
            }
            Divider()
        }
        Button("Deaktivieren") { store.deactivate([record.id]) }
        Button("Im Finder zeigen") { store.showInFinder([record.id]) }
    }

    private func loadExternal() async {
        checkingExternal = true
        let libraryPaths = Set(store.fonts.map { ActivationService.normalizedPath($0.fileURL) })
        let result = await Task.detached(priority: .userInitiated) {
            ExternalFonts.byPostScriptName(excludingPaths: libraryPaths)
        }.value
        external = result
        checkingExternal = false
    }
}

private struct ConflictHeader: View {
    let group: ConflictGroup

    var body: some View {
        HStack {
            Text(group.postScriptName).font(.headline)
            Spacer()
            if group.hasLibraryDuplicates {
                Text("\(group.records.count) Fassungen in der Bibliothek")
            }
            if !group.externalLocations.isEmpty {
                Text(group.externalLocations.contains { $0.path.hasPrefix("/System/") } ? "auch Systemschrift" : "auch ausserhalb")
            }
        }
        .font(.caption)
    }
}

private struct ConflictRecordRow: View {
    let record: FontRecord
    let isSuggested: Bool

    var body: some View {
        HStack(spacing: 8) {
            StatusIcon(record: record)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(record.fullName)
                    if isSuggested {
                        Text("Empfohlen")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.green.opacity(0.2)))
                            .foregroundStyle(.green)
                    }
                }
                Text([FormatPreference.label(record), record.versionText, record.fileURL.pathExtension.lowercased(),
                      "\(record.glyphCount) Glyphen",
                      ByteCountFormatter.string(fromByteCount: record.fileSize, countStyle: .file)]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                Text((record.fileURL.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ExternalLocationRow: View {
    let url: URL

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: url.path.hasPrefix("/System/") ? "apple.logo" : "folder")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                Text(url.path.hasPrefix("/System/")
                     ? "Systemschrift von macOS, kann nicht deaktiviert werden"
                     : "Ausserhalb von Fontwerk: \(ActivationService.displayPath(url))")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if !url.path.hasPrefix("/System/") {
                Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
        .foregroundStyle(.secondary)
    }
}
