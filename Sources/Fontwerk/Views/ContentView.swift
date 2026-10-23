import SwiftUI

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
            FontListView(source: sidebarSelection ?? .all, search: search, selection: $selection)
                .navigationSplitViewColumnWidth(min: 420, ideal: 600)
        } detail: {
            PreviewPane(fontIDs: selection)
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
            }
        }
        .onChange(of: sidebarSelection) { _, _ in
            selection.removeAll()
        }
    }
}
