import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: LibraryStore
    @Binding var selection: SidebarItem?

    @State private var expandedFolders: Set<UUID> = []
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
                SetTreeRows(parentID: nil, expanded: $expandedFolders, actions: actions)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Menu {
                    Button("Neues Set") { newSet(in: selectedFolderID) }
                    Button("Neuer Ordner") { newFolder(in: selectedFolderID) }
                } label: {
                    Label("Neu", systemImage: "plus")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
                Spacer()
            }
            .padding(8)
        }
        .alert("Umbenennen", isPresented: $showRename) {
            TextField("Name", text: $nameField)
            Button("Sichern") {
                if let id = renamingSetID { store.renameSet(id, to: nameField) }
            }
            Button("Abbrechen", role: .cancel) {}
        }
        .confirmationDialog(
            deletingTitle,
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
            Text(deletingIsFolder
                 ? "Die Sets im Ordner bleiben erhalten und rücken eine Ebene nach oben. Die Schriften bleiben in der Bibliothek."
                 : "Die Schriften bleiben in der Bibliothek, nur das Set wird entfernt.")
        }
    }

    private var actions: SetRowActions {
        SetRowActions(
            rename: { set in
                renamingSetID = set.id
                nameField = set.name
                showRename = true
            },
            delete: { set in deletingSetID = set.id },
            newSet: { parent in newSet(in: parent) },
            newFolder: { parent in newFolder(in: parent) }
        )
    }

    /// New items go into the selected folder, or next to the selected set.
    private var selectedFolderID: UUID? {
        guard case .set(let id) = selection, let set = store.set(withID: id) else { return nil }
        return set.isFolder ? set.id : set.parentID
    }

    private var deletingIsFolder: Bool {
        deletingSetID.flatMap { store.set(withID: $0) }?.isFolder ?? false
    }

    private var deletingTitle: String {
        deletingIsFolder ? "Ordner löschen?" : "Set löschen?"
    }

    private func newSet(in parent: UUID?) {
        let id = store.createSet(named: "Neues Set", in: parent)
        if let parent { expandedFolders.insert(parent) }
        selection = .set(id)
        startRename(id)
    }

    private func newFolder(in parent: UUID?) {
        let id = store.createFolder(named: "Neuer Ordner", in: parent)
        if let parent { expandedFolders.insert(parent) }
        selection = .set(id)
        startRename(id)
    }

    private func startRename(_ id: UUID) {
        renamingSetID = id
        nameField = store.set(withID: id)?.name ?? ""
        showRename = true
    }

    private func row(_ title: String, icon: String, item: SidebarItem) -> some View {
        Label(title, systemImage: icon)
            .badge(store.count(item))
            .tag(item)
    }
}

struct SetRowActions {
    var rename: (FontSet) -> Void
    var delete: (FontSet) -> Void
    var newSet: (UUID?) -> Void
    var newFolder: (UUID?) -> Void
}

/// One level of the set tree; folders contain another level.
struct SetTreeRows: View {
    @EnvironmentObject private var store: LibraryStore
    let parentID: UUID?
    @Binding var expanded: Set<UUID>
    let actions: SetRowActions

    var body: some View {
        ForEach(store.childSets(of: parentID)) { set in
            if set.isFolder {
                DisclosureGroup(isExpanded: Binding(
                    get: { expanded.contains(set.id) },
                    set: { isOpen in
                        if isOpen { expanded.insert(set.id) } else { expanded.remove(set.id) }
                    }
                )) {
                    SetTreeRows(parentID: set.id, expanded: $expanded, actions: actions)
                } label: {
                    label(for: set)
                }
            } else {
                label(for: set)
            }
        }
    }

    private func label(for set: FontSet) -> some View {
        Label(set.name, systemImage: icon(for: set))
            .badge(store.fontIDs(inSet: set.id).count)
            .help(set.applicationPath ?? "")
            .tag(SidebarItem.set(set.id))
            .contextMenu { menu(for: set) }
    }

    private func icon(for set: FontSet) -> String {
        if set.isFolder { return "folder" }
        if set.applicationPath != nil { return "app" }
        return "square.stack"
    }

    @ViewBuilder
    private func menu(for set: FontSet) -> some View {
        Button(set.isFolder ? "Alle Schriften im Ordner aktivieren" : "Set aktivieren") {
            store.activate(store.fontIDs(inSet: set.id))
        }
        Button(set.isFolder ? "Alle Schriften im Ordner deaktivieren" : "Set deaktivieren") {
            store.deactivate(store.fontIDs(inSet: set.id))
        }
        Divider()
        if set.isFolder {
            Button("Neues Set in diesem Ordner") { actions.newSet(set.id) }
            Button("Neuer Unterordner") { actions.newFolder(set.id) }
            Divider()
        }
        Button("Umbenennen …") { actions.rename(set) }
        Menu("Verschieben nach") {
            Button("Oberste Ebene") { store.moveSet(set.id, to: nil) }
                .disabled(set.parentID == nil)
            let blocked = store.descendantIDs(of: set.id).union([set.id])
            let targets = store.foldersByPath.filter { !blocked.contains($0.id) }
            if !targets.isEmpty { Divider() }
            ForEach(targets) { folder in
                Button(store.displayPath(of: folder)) { store.moveSet(set.id, to: folder.id) }
                    .disabled(set.parentID == folder.id)
            }
        }
        Divider()
        Button(set.isFolder ? "Ordner löschen …" : "Set löschen …", role: .destructive) { actions.delete(set) }
    }
}
