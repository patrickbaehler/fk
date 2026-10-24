import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var sidebarSelection: SidebarItem? = .all
    @State private var selection = Set<FontRecord.ID>()
    @State private var search = ""

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $sidebarSelection)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } content: {
            Group {
                if sidebarSelection == .conflicts {
                    ConflictsView(selection: $selection)
                } else {
                    FontListView(source: sidebarSelection ?? .all, search: search, selection: $selection)
                }
            }
            .navigationSplitViewColumnWidth(min: 420, ideal: 600)
        } detail: {
            PreviewPane(fontIDs: selection)
                .alert(
                    store.infoAlert?.title ?? "",
                    isPresented: Binding(
                        get: { store.infoAlert != nil },
                        set: { if !$0 { store.infoAlert = nil } }
                    ),
                    presenting: store.infoAlert
                ) { _ in
                    Button("OK", role: .cancel) {}
                } message: { alert in
                    Text(alert.text)
                }
        }
        .sheet(isPresented: $store.showFEXImport) {
            FEXImportSheet()
                .environmentObject(store)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Schriften suchen")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    store.presentImportPanel()
                } label: {
                    Label("Importieren", systemImage: "square.and.arrow.down")
                }
                .help("Schriften importieren")

                Menu {
                    Button("Bis zum Abmelden") { store.activate(selection, scope: .session) }
                    Button("Dauerhaft") { store.activate(selection, scope: .persistent) }
                } label: {
                    Label("Aktivieren", systemImage: "checkmark.circle")
                } primaryAction: {
                    store.activate(selection)
                }
                .disabled(selection.isEmpty)
                .help("Auswahl aktivieren")

                Button {
                    store.deactivate(selection)
                } label: {
                    Label("Deaktivieren", systemImage: "xmark.circle")
                }
                .disabled(selection.isEmpty)
                .help("Auswahl deaktivieren")

                Button {
                    printSampleSheet()
                } label: {
                    Label("Drucken", systemImage: "printer")
                }
                .keyboardShortcut("p", modifiers: .command)
                .help("Musterblatt der Auswahl drucken (ohne Auswahl: alle Schriften der Liste)")
            }
        }
        .onChange(of: sidebarSelection) { _, _ in
            selection.removeAll()
        }
        .alert(
            "Einige Schriften sind weiterhin aktiv",
            isPresented: Binding(
                get: { store.stillActiveReport != nil },
                set: { if !$0 { store.stillActiveReport = nil } }
            ),
            presenting: store.stillActiveReport
        ) { report in
            Button("Im Finder zeigen") {
                NSWorkspace.shared.activateFileViewerSelecting(report.allLocations)
            }
            Button("OK", role: .cancel) {}
        } message: { report in
            Text(report.summary)
        }
    }

    private func printSampleSheet() {
        let records: [FontRecord]
        if selection.isEmpty {
            records = store.records(in: sidebarSelection ?? .all, matching: search)
        } else {
            records = store.records(withIDs: selection)
        }
        let sorted = records.sorted { ($0.familyName, $0.styleName) < ($1.familyName, $1.styleName) }
        let sample = UserDefaults.standard.string(forKey: "previewText")
            ?? "Franz jagt im komplett verwahrlosten Taxi quer durch Bayern"
        SampleSheetPrinter.print(sorted, sampleText: sample)
    }
}
