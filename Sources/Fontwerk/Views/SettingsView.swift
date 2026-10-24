import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @AppStorage("wysiwygNames") private var wysiwygNames = false

    var body: some View {
        Form {
            Section("Import") {
                Toggle("Schriften beim Import in den Fontwerk-Ordner kopieren", isOn: $store.copyOnImport)
                Text("Ohne Kopie verweist Fontwerk auf die Dateien an ihrem bisherigen Ort.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Aktivierung") {
                Picker("Standard beim Aktivieren", selection: $store.defaultScope) {
                    Text("Bis zum Abmelden").tag(ActivationState.session)
                    Text("Dauerhaft").tag(ActivationState.persistent)
                }
                Toggle("Programm-Sets beim Start des Programms aktivieren", isOn: $store.autoActivateProgramSets)
                Text("Beim Beenden des Programms deaktiviert Fontwerk die Schriften wieder, sofern du sie nicht inzwischen dauerhaft aktiviert hast.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Darstellung") {
                Toggle("Schriftnamen in der Liste in ihrer eigenen Schrift zeigen", isOn: $wysiwygNames)
            }
            Section("Speicherort") {
                LabeledContent("Bibliothek") {
                    Button("Im Finder zeigen") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.supportDirectory])
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
    }
}
