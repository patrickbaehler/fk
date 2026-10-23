import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: LibraryStore
    @Binding var selection: SidebarItem?

    @State private var renamingSetID: UUID? = nil
    @State private var nameField = ""
    @State private var showRename = false
    @State private var deletingSetID: UUID? = nil

    var body: some View {
        List(selection: $selection) {
            Section("Bibliothek") {
                row("Alle Schriften", icon: "textformat", item: .all)
                row("Aktiv", icon: "checkmark.circle", item: .active)
                row("Inaktiv", icon: "circle", item: .inactive)
                row("Favoriten", icon: "star", item: .favorites)
                row("Kürzlich importiert", icon: "clock", item: .recent)
                if store.count(.missing) > 0 {
                    row("Fehlende Dateien", icon: "exclamationmark.triangle", item: .missing)
                }
            }

            Section("Sets") {
                ForEach(store.sets) { set in
                    Label(set.name, systemImage: "folder")
                        .badge(set.fontIDs.count)
                        .tag(SidebarItem.set(set.id))
                        .contextMenu {
                            Button("Set aktivieren") { store.activate(store.fontIDs(inSet: set.id)) }
                            Button("Set deaktivieren") { store.deactivate(store.fontIDs(inSet: set.id)) }
                            Divider()
                            Button("Umbenennen …") {
                                renamingSetID = set.id
                                nameField = set.name
                                showRename = true
                            }
                            Button("Set löschen …", role: .destructive) { deletingSetID = set.id }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    let id = store.createSet(named: "Neues Set")
                    selection = .set(id)
                    renamingSetID = id
                    nameField = store.set(withID: id)?.name ?? ""
                    showRename = true
                } label: {
                    Label("Neues Set", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(8)
        }
        .alert("Set umbenennen", isPresented: $showRename) {
            TextField("Name", text: $nameField)
            Button("Sichern") {
                if let id = renamingSetID { store.renameSet(id, to: nameField) }
            }
            Button("Abbrechen", role: .cancel) {}
        }
        .confirmationDialog(
            "Set löschen?",
            isPresented: Binding(get: { deletingSetID != nil }, set: { if !$0 { deletingSetID = nil } })
        ) {
            Button("Löschen", role: .destructive) {
                if let id = deletingSetID {
                    if selection == .set(id) { selection = .all }
                    store.deleteSet(id)
                }
                deletingSetID = nil
            }
        } message: {
            Text("Die Schriften bleiben in der Bibliothek, nur das Set wird entfernt.")
        }
    }

    private func row(_ title: String, icon: String, item: SidebarItem) -> some View {
        Label(title, systemImage: icon)
            .badge(store.count(item))
            .tag(item)
    }
}
