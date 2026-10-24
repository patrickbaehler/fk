import SwiftUI
import AppKit

/// Reads a FontExplorer X library, shows what will be taken over and
/// starts the import.
struct FEXImportSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case loading
        case failed(String)
        case ready(FEXImportPlan)
        case notFound
    }

    @State private var phase: Phase = .loading
    @State private var copyFiles = true
    @State private var restoreActivation = true
    @State private var importTags = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("FontExplorer-Bibliothek übernehmen")
                .font(.title2.bold())

            switch phase {
            case .loading:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("FontExplorer-Bibliothek wird gelesen …")
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            case .notFound:
                Text("Am üblichen Ort wurde keine FontExplorer-Bibliothek gefunden. Wähle die Datei „FontExplorer X.fexdb“ selbst aus.")
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let reason):
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            case .ready(let plan):
                summary(plan)
                options
            }

            HStack {
                Button("Andere Datei wählen …") { chooseFile() }
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Importieren") { startImport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isReady)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task { await load(FEXImporter.defaultDatabaseURL, reportMissing: false) }
        .onAppear { copyFiles = store.copyOnImport }
    }

    private var isReady: Bool {
        if case .ready(let plan) = phase { return !plan.importable.isEmpty }
        return false
    }

    private func summary(_ plan: FEXImportPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(plan.sourceURL.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                summaryRow("Schriftdateien zum Übernehmen", plan.importable.count)
                summaryRow("Sets", plan.setCount)
                summaryRow("Ordner", plan.folderCount)
                if plan.applicationSetCount > 0 { summaryRow("Programm-Sets", plan.applicationSetCount) }
                summaryRow("In FontExplorer aktiv", plan.activeCount)
                if plan.skippedSystem > 0 { summaryRow("Systemschriften (bleiben bei macOS)", plan.skippedSystem) }
                if plan.skippedAdobe > 0 { summaryRow("Adobe Fonts (bleiben bei Creative Cloud)", plan.skippedAdobe) }
                if !plan.missing.isEmpty { summaryRow("Dateien nicht gefunden", plan.missing.count) }
                if plan.library.smartSetCount > 0 { summaryRow("Smart Sets (werden nicht übernommen)", plan.library.smartSetCount) }
            }
            .font(.callout)
            if !plan.library.version.isEmpty {
                Text("Erstellt mit FontExplorer X Pro \(plan.library.version)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func summaryRow(_ label: String, _ value: Int) -> some View {
        GridRow {
            Text(label)
            Text("\(value)").monospacedDigit().gridColumnAlignment(.trailing)
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Schriftdateien in den Fontwerk-Ordner kopieren", isOn: $copyFiles)
            Text(copyFiles
                 ? "Die Schriften liegen danach unabhängig von FontExplorer in Fontwerks eigenem Ordner. FontExplorers Dateien bleiben unverändert."
                 : "Fontwerk verweist auf die Dateien in FontExplorers Ordner. Lösche diesen dann später nicht.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Schriften aktivieren, die in FontExplorer aktiv sind", isOn: $restoreActivation)
            Toggle("Klassifikationen und Tags als Tags übernehmen", isOn: $importTags)
            Label("Beende FontExplorer vor dem Import und schalte seinen automatischen Start aus, damit Schriften nicht doppelt aktiv sind.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Datei „FontExplorer X.fexdb“ auswählen"
        panel.prompt = "Auswählen"
        let folder = FEXImporter.defaultDatabaseURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: folder.path) { panel.directoryURL = folder }
        if panel.runModal() == .OK, let url = panel.url {
            Task { await load(url, reportMissing: true) }
        }
    }

    private func load(_ url: URL, reportMissing: Bool) async {
        guard FileManager.default.fileExists(atPath: url.path) else {
            phase = reportMissing ? .failed("Die Datei wurde nicht gefunden.") : .notFound
            return
        }
        phase = .loading
        let result: Result<FEXImportPlan, Error> = await Task.detached(priority: .userInitiated) {
            do {
                let library = try FEXImporter.read(databaseAt: url)
                return .success(FEXImporter.makePlan(for: library, sourceURL: url))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let plan): phase = .ready(plan)
        case .failure(let error): phase = .failed(error.localizedDescription)
        }
    }

    private func startImport() {
        guard case .ready(let plan) = phase else { return }
        store.runFEXImport(plan, options: FEXImportOptions(
            copyFiles: copyFiles, restoreActivation: restoreActivation, importTags: importTags))
        dismiss()
    }
}
