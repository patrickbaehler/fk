import Foundation
import AppKit
import CoreText

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var fonts: [FontRecord] = []
    @Published private(set) var sets: [FontSet] = []
    @Published private(set) var importProgress: ImportProgress? = nil
    @Published var message: String? = nil

    @Published var copyOnImport: Bool {
        didSet { UserDefaults.standard.set(copyOnImport, forKey: "copyOnImport") }
    }
    @Published var defaultScope: ActivationState {
        didSet { UserDefaults.standard.set(defaultScope.rawValue, forKey: "defaultScope") }
    }

    let supportDirectory: URL
    let managedFontsDirectory: URL
    private let libraryFile: URL
    private var saveTask: Task<Void, Never>?

    init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fontwerk", isDirectory: true)
        supportDirectory = base
        managedFontsDirectory = base.appendingPathComponent("Fonts", isDirectory: true)
        libraryFile = base.appendingPathComponent("library.json")
        try? fm.createDirectory(at: managedFontsDirectory, withIntermediateDirectories: true)

        copyOnImport = UserDefaults.standard.object(forKey: "copyOnImport") as? Bool ?? true
        let storedScope = UserDefaults.standard.string(forKey: "defaultScope").flatMap(ActivationState.init(rawValue:))
        defaultScope = (storedScope == nil || storedScope == .inactive) ? .session : storedScope!

        load()
        refreshActivationStates()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: libraryFile) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let library = try decoder.decode(LibraryData.self, from: data)
            fonts = library.fonts
            sets = library.sets
        } catch {
            let backup = libraryFile.deletingLastPathComponent()
                .appendingPathComponent("library-defekt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: libraryFile, to: backup)
            message = "Die Bibliothek konnte nicht gelesen werden. Eine Kopie liegt unter \(backup.lastPathComponent)."
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = LibraryData(version: 1, fonts: fonts, sets: sets)
        let url = libraryFile
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    // MARK: - Queries

    func records(in source: SidebarItem, matching search: String) -> [FontRecord] {
        let base: [FontRecord]
        switch source {
        case .all: base = fonts
        case .active: base = fonts.filter { $0.activation.isActive }
        case .inactive: base = fonts.filter { !$0.activation.isActive }
        case .favorites: base = fonts.filter { $0.isFavorite }
        case .missing: base = fonts.filter { $0.isMissing }
        case .recent:
            let cutoff = Date().addingTimeInterval(-14 * 24 * 3600)
            base = fonts.filter { $0.importedAt >= cutoff }
        case .set(let id):
            let ids = Set(sets.first { $0.id == id }?.fontIDs ?? [])
            base = fonts.filter { ids.contains($0.id) }
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return base }
        return base.filter { record in
            record.fullName.localizedCaseInsensitiveContains(query)
                || record.familyName.localizedCaseInsensitiveContains(query)
                || record.postScriptName.localizedCaseInsensitiveContains(query)
                || record.foundryText.localizedCaseInsensitiveContains(query)
                || record.tags.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    func count(_ source: SidebarItem) -> Int { records(in: source, matching: "").count }

    func records(withIDs ids: Set<UUID>) -> [FontRecord] {
        fonts.filter { ids.contains($0.id) }
    }

    private func files(for ids: Set<UUID>) -> [URL] {
        var seen = Set<URL>()
        var result: [URL] = []
        for record in fonts where ids.contains(record.id) && !seen.contains(record.fileURL) {
            seen.insert(record.fileURL)
            result.append(record.fileURL)
        }
        return result
    }

    // MARK: - Activation

    func activate(_ ids: Set<UUID>, scope: ActivationState? = nil) {
        let target = scope ?? defaultScope
        guard target.isActive else { deactivate(ids); return }
        var failures: [String] = []
        var changed = 0
        for url in files(for: ids) {
            let current = fonts.first { $0.fileURL == url }?.activation ?? .inactive
            if current == target { continue }
            guard FileManager.default.fileExists(atPath: url.path) else {
                failures.append("\(url.lastPathComponent): Datei fehlt")
                continue
            }
            do {
                if current.isActive { try ActivationService.unregister(url, from: current) }
                try ActivationService.register(url, as: target)
                setActivation(target, forFile: url)
                changed += 1
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        report(changed: changed, verb: "aktiviert", failures: failures)
    }

    func deactivate(_ ids: Set<UUID>) {
        var failures: [String] = []
        var changed = 0
        for url in files(for: ids) {
            let current = fonts.first { $0.fileURL == url }?.activation ?? .inactive
            guard current.isActive else { continue }
            do {
                try ActivationService.unregister(url, from: current)
                setActivation(.inactive, forFile: url)
                changed += 1
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        report(changed: changed, verb: "deaktiviert", failures: failures)
    }

    func toggleActivation(_ ids: Set<UUID>) {
        let anyInactive = fonts.contains { ids.contains($0.id) && !$0.activation.isActive }
        if anyInactive { activate(ids) } else { deactivate(ids) }
    }

    private func setActivation(_ state: ActivationState, forFile url: URL) {
        for index in fonts.indices where fonts[index].fileURL == url {
            fonts[index].activation = state
        }
        scheduleSave()
    }

    private func report(changed: Int, verb: String, failures: [String]) {
        var parts: [String] = []
        if changed > 0 { parts.append("\(changed) Datei\(changed == 1 ? "" : "en") \(verb).") }
        if !failures.isEmpty {
            parts.append("Fehler bei \(failures.count): " + failures.prefix(3).joined(separator: "; ") + (failures.count > 3 ? " …" : ""))
        }
        if !parts.isEmpty { message = parts.joined(separator: " ") }
    }

    /// Brings stored states in line with what macOS reports, e.g. after
    /// a logout ended session activations or files were moved.
    func refreshActivationStates() {
        let available = ActivationService.availableFontPaths()
        let fm = FileManager.default
        var changed = false
        for index in fonts.indices {
            let url = fonts[index].fileURL
            let missing = !fm.fileExists(atPath: url.path)
            if fonts[index].isMissing != missing {
                fonts[index].isMissing = missing
                changed = true
            }
            if fonts[index].activation.isActive && !available.contains(ActivationService.normalizedPath(url)) {
                fonts[index].activation = .inactive
                changed = true
            }
        }
        if changed { scheduleSave() }
    }

    // MARK: - Import

    func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Importieren"
        panel.message = "Schriftdateien oder Ordner auswählen"
        if panel.runModal() == .OK {
            importFonts(from: panel.urls)
        }
    }

    func importFonts(from urls: [URL]) {
        guard importProgress == nil, !urls.isEmpty else { return }
        importProgress = ImportProgress(total: 0, done: 0)
        let copy = copyOnImport
        let destination = managedFontsDirectory
        let knownPaths = Set(fonts.map { $0.fileURL.path })
        let knownKeys = Set(fonts.map(\.duplicateKey))

        Task.detached(priority: .userInitiated) { [weak self] in
            let files = FontScanner.collectFontFiles(in: urls)
            await MainActor.run { self?.importProgress = ImportProgress(total: files.count, done: 0) }

            var newRecords: [FontRecord] = []
            var duplicates = 0
            var failures: [String] = []
            var keys = knownKeys

            for (number, file) in files.enumerated() {
                let faces = FontScanner.scan(file)
                if faces.isEmpty {
                    failures.append(file.lastPathComponent)
                } else if knownPaths.contains(file.path) {
                    duplicates += faces.count
                } else {
                    let fresh = faces.filter { !keys.contains($0.duplicateKey) }
                    duplicates += faces.count - fresh.count
                    if !fresh.isEmpty {
                        var target = file
                        if copy {
                            do {
                                target = try FontScanner.copyIntoLibrary(file, familyName: fresh[0].familyName, root: destination)
                            } catch {
                                failures.append(file.lastPathComponent)
                                continue
                            }
                        }
                        for face in fresh {
                            keys.insert(face.duplicateKey)
                            newRecords.append(FontRecord(scanned: face, fileURL: target))
                        }
                    }
                }
                if number % 10 == 0 || number == files.count - 1 {
                    let done = number + 1
                    await MainActor.run { self?.importProgress?.done = done }
                }
            }

            let added = newRecords
            let skipped = duplicates
            let failed = failures
            await MainActor.run {
                self?.finishImport(added: added, duplicates: skipped, failures: failed)
            }
        }
    }

    private func finishImport(added: [FontRecord], duplicates: Int, failures: [String]) {
        fonts.append(contentsOf: added)
        importProgress = nil
        scheduleSave()
        var parts = ["\(added.count) Schriften importiert."]
        if duplicates > 0 { parts.append("\(duplicates) Duplikate übersprungen.") }
        if !failures.isEmpty { parts.append("\(failures.count) Dateien nicht lesbar.") }
        message = parts.joined(separator: " ")
    }

    // MARK: - Editing

    private func update(_ ids: Set<UUID>, _ change: (inout FontRecord) -> Void) {
        for index in fonts.indices where ids.contains(fonts[index].id) {
            change(&fonts[index])
        }
        scheduleSave()
    }

    func setRating(_ ids: Set<UUID>, rating: Int) {
        update(ids) { $0.rating = max(0, min(5, rating)) }
    }

    func setFavorite(_ ids: Set<UUID>, _ favorite: Bool) {
        update(ids) { $0.isFavorite = favorite }
    }

    func setTags(_ ids: Set<UUID>, tags: [String]) {
        let cleaned = tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        update(ids) { $0.tags = cleaned }
    }

    func showInFinder(_ ids: Set<UUID>) {
        let urls = files(for: ids)
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    /// Removes fonts from the library. Files Fontwerk copied into its own
    /// folder go to the Trash once no record uses them any more.
    func remove(_ ids: Set<UUID>) {
        deactivate(ids)
        let removedFiles = Set(files(for: ids))
        fonts.removeAll { ids.contains($0.id) }
        for index in sets.indices {
            sets[index].fontIDs.removeAll { ids.contains($0) }
        }
        let stillUsed = Set(fonts.map(\.fileURL))
        let managedRoot = managedFontsDirectory.standardizedFileURL.path
        for url in removedFiles where !stillUsed.contains(url) && url.standardizedFileURL.path.hasPrefix(managedRoot) {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        FontFaceCache.shared.clear()
        scheduleSave()
        message = "\(ids.count) Schriften aus der Bibliothek entfernt."
    }

    // MARK: - Sets

    @discardableResult
    func createSet(named name: String, with ids: Set<UUID> = []) -> UUID {
        let set = FontSet(id: UUID(), name: uniqueSetName(name), fontIDs: fonts.filter { ids.contains($0.id) }.map(\.id))
        sets.append(set)
        scheduleSave()
        return set.id
    }

    private func uniqueSetName(_ name: String) -> String {
        let base = name.trimmingCharacters(in: .whitespaces).isEmpty ? "Neues Set" : name
        var candidate = base
        var counter = 2
        while sets.contains(where: { $0.name == candidate }) {
            candidate = "\(base) \(counter)"
            counter += 1
        }
        return candidate
    }

    func renameSet(_ id: UUID, to name: String) {
        guard let index = sets.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        sets[index].name = trimmed
        scheduleSave()
    }

    func deleteSet(_ id: UUID) {
        sets.removeAll { $0.id == id }
        scheduleSave()
    }

    func add(_ ids: Set<UUID>, toSet setID: UUID) {
        guard let index = sets.firstIndex(where: { $0.id == setID }) else { return }
        let existing = Set(sets[index].fontIDs)
        let additions = fonts.map(\.id).filter { ids.contains($0) && !existing.contains($0) }
        sets[index].fontIDs.append(contentsOf: additions)
        scheduleSave()
    }

    func remove(_ ids: Set<UUID>, fromSet setID: UUID) {
        guard let index = sets.firstIndex(where: { $0.id == setID }) else { return }
        sets[index].fontIDs.removeAll { ids.contains($0) }
        scheduleSave()
    }

    func fontIDs(inSet setID: UUID) -> Set<UUID> {
        Set(sets.first { $0.id == setID }?.fontIDs ?? [])
    }

    func set(withID id: UUID) -> FontSet? {
        sets.first { $0.id == id }
    }
}
