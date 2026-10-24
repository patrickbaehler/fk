import Foundation
import AppKit
import CoreText

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var fonts: [FontRecord] = []
    @Published private(set) var sets: [FontSet] = []
    @Published private(set) var importProgress: ImportProgress? = nil
    @Published var message: String? = nil
    /// Set after a deactivation when some fonts stayed available to apps.
    @Published var stillActiveReport: StillActiveReport? = nil
    @Published var infoAlert: InfoAlert? = nil
    @Published var showFEXImport = false

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
        defaultScope = (storedScope == .persistent) ? .persistent : .session

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
            let ids = fontIDs(inSet: id)
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

    private func stateByFile() -> [URL: ActivationState] {
        var result: [URL: ActivationState] = [:]
        for record in fonts where result[record.fileURL] == nil {
            result[record.fileURL] = record.activation
        }
        return result
    }

    // MARK: - Activation

    @discardableResult
    func activate(_ ids: Set<UUID>, scope: ActivationState? = nil) -> (changed: Int, failures: [String]) {
        let target = (scope == .persistent || (scope == nil && defaultScope == .persistent)) ? ActivationState.persistent : .session
        let states = stateByFile()
        var changes: [URL: ActivationState] = [:]
        var failures: [String] = []
        for url in files(for: ids) {
            let current = states[url] ?? .inactive
            if current == target { continue }
            guard FileManager.default.fileExists(atPath: url.path) else {
                failures.append("\(url.lastPathComponent): Datei fehlt")
                continue
            }
            do {
                if current.isActive { try ActivationService.unregisterEverywhere(url) }
                try ActivationService.register(url, as: target)
                changes[url] = target
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        apply(changes)
        report(changed: changes.count, verb: "aktiviert", failures: failures)
        return (changes.count, failures)
    }

    /// Deactivates regardless of the recorded state, so a font whose
    /// state was recorded wrongly can still be switched off.
    func deactivate(_ ids: Set<UUID>) {
        let states = stateByFile()
        var changes: [URL: ActivationState] = [:]
        var changed = 0
        var failures: [String] = []
        for url in files(for: ids) {
            let wasActive = states[url]?.isActive ?? false
            do {
                let removed = try ActivationService.unregisterEverywhere(url)
                if removed || wasActive { changed += 1 }
                changes[url] = .inactive
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        apply(changes)
        report(changed: changed, verb: "deaktiviert", failures: failures)
        verifyDeactivation(of: ids)
    }

    /// Checks shortly afterwards whether the fonts really disappeared
    /// for apps, and explains why when they did not.
    private func verifyDeactivation(of ids: Set<UUID>) {
        let records = Array(fonts.filter { ids.contains($0.id) }.prefix(300))
        guard !records.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            let available = ActivationService.availableFontPaths()
            var entries: [StillActiveReport.Entry] = []
            var stuckFiles = Set<URL>()
            for record in records {
                let ownPath = ActivationService.normalizedPath(record.fileURL)
                var locations = ActivationService.activeLocations(ofPostScriptName: record.postScriptName)
                    .filter { ActivationService.normalizedPath($0) != ownPath }
                if available.contains(ownPath) {
                    stuckFiles.insert(record.fileURL)
                    locations.insert(record.fileURL, at: 0)
                }
                if !locations.isEmpty {
                    entries.append(.init(fontName: record.fullName, locations: locations))
                }
            }
            let stuck = stuckFiles
            let found = entries
            await MainActor.run {
                guard let self else { return }
                self.apply(Dictionary(uniqueKeysWithValues: stuck.map { ($0, ActivationState.external) }))
                if !found.isEmpty { self.stillActiveReport = StillActiveReport(entries: found) }
            }
        }
    }

    func toggleActivation(_ ids: Set<UUID>) {
        let anyInactive = fonts.contains { ids.contains($0.id) && !$0.activation.isActive }
        if anyInactive { activate(ids) } else { deactivate(ids) }
    }

    private func apply(_ changes: [URL: ActivationState]) {
        guard !changes.isEmpty else { return }
        for index in fonts.indices {
            if let state = changes[fonts[index].fileURL] { fonts[index].activation = state }
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
        var pathCache: [URL: (missing: Bool, available: Bool)] = [:]
        var changed = false
        for index in fonts.indices {
            let url = fonts[index].fileURL
            let status: (missing: Bool, available: Bool)
            if let cached = pathCache[url] {
                status = cached
            } else {
                status = (!fm.fileExists(atPath: url.path), available.contains(ActivationService.normalizedPath(url)))
                pathCache[url] = status
            }
            if fonts[index].isMissing != status.missing {
                fonts[index].isMissing = status.missing
                changed = true
            }
            if fonts[index].activation.isActive && !status.available {
                fonts[index].activation = .inactive
                changed = true
            } else if !fonts[index].activation.isActive && status.available {
                fonts[index].activation = .external
                changed = true
            }
        }
        if changed { scheduleSave() }
    }

    // MARK: - Import of font files

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
            var fromMacOSFolders = 0
            var keys = knownKeys

            for (number, file) in files.enumerated() {
                if ActivationService.isInMacOSFontFolder(file) { fromMacOSFolders += 1 }
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
            let systemFolderFiles = fromMacOSFolders
            await MainActor.run {
                self?.finishImport(added: added, duplicates: skipped, failures: failed, fromMacOSFolders: systemFolderFiles)
            }
        }
    }

    private func finishImport(added: [FontRecord], duplicates: Int, failures: [String], fromMacOSFolders: Int) {
        fonts.append(contentsOf: added)
        importProgress = nil
        scheduleSave()
        refreshActivationStates()
        var parts = ["\(added.count) Schriften importiert."]
        if duplicates > 0 { parts.append("\(duplicates) Duplikate übersprungen.") }
        if !failures.isEmpty { parts.append("\(failures.count) Dateien nicht lesbar.") }
        if fromMacOSFolders > 0 {
            parts.append("\(fromMacOSFolders) Dateien stammen aus einem Schriftordner von macOS; die Originale dort bleiben aktiv, bis du sie aus dem Ordner entfernst.")
        }
        message = parts.joined(separator: " ")
    }

    // MARK: - Import of a FontExplorer X library

    func runFEXImport(_ plan: FEXImportPlan, options: FEXImportOptions) {
        guard importProgress == nil else { return }
        importProgress = ImportProgress(total: plan.importable.count, done: 0)
        let destination = managedFontsDirectory
        var existingByPath: [String: [UUID]] = [:]
        for record in fonts {
            existingByPath[ActivationService.normalizedPath(record.fileURL), default: []].append(record.id)
        }
        var existingByKey: [String: UUID] = [:]
        for record in fonts where existingByKey[record.duplicateKey] == nil {
            existingByKey[record.duplicateKey] = record.id
        }
        let knownPaths = existingByPath
        let knownKeys = existingByKey

        Task.detached(priority: .userInitiated) { [weak self] in
            var newRecords: [FontRecord] = []
            var containerRecords: [Int64: [UUID]] = [:]
            var keyToID = knownKeys
            var failures: [String] = []
            var copiedFolders: [String: URL] = [:]
            let total = plan.importable.count

            for (number, container) in plan.importable.enumerated() {
                defer {
                    if number % 20 == 0 || number == total - 1 {
                        let done = number + 1
                        Task { @MainActor in self?.importProgress?.done = done }
                    }
                }
                guard let source = plan.resolvedURLs[container.id] else { continue }
                if let ids = knownPaths[ActivationService.normalizedPath(source)] {
                    containerRecords[container.id] = ids
                    continue
                }
                let faces = FontScanner.scan(source)
                if faces.isEmpty {
                    failures.append(source.lastPathComponent)
                    continue
                }
                var ids: [UUID] = []
                var fresh: [ScannedFace] = []
                for face in faces {
                    if let id = keyToID[face.duplicateKey] { ids.append(id) } else { fresh.append(face) }
                }
                if !fresh.isEmpty {
                    var target = source
                    if options.copyFiles {
                        do {
                            if source.path.contains(FEXImporter.fontExplorerLibraryMarker) {
                                target = try FontScanner.copyFolderIntoLibrary(
                                    containing: source, familyName: fresh[0].familyName,
                                    root: destination, copiedFolders: &copiedFolders)
                            } else {
                                target = try FontScanner.copyIntoLibrary(source, familyName: fresh[0].familyName, root: destination)
                            }
                        } catch {
                            failures.append(source.lastPathComponent)
                            continue
                        }
                    }
                    let info = plan.library.faceInfo[container.id] ?? [:]
                    for face in fresh {
                        var record = FontRecord(scanned: face, fileURL: target)
                        if let added = container.addedDate { record.importedAt = added }
                        if let faceInfo = info[face.postScriptName] {
                            record.rating = max(0, min(5, faceInfo.rating))
                            if options.importTags { record.tags = faceInfo.tags }
                        }
                        keyToID[face.duplicateKey] = record.id
                        ids.append(record.id)
                        newRecords.append(record)
                    }
                }
                containerRecords[container.id] = ids
            }

            let added = newRecords
            let mapping = containerRecords
            let failed = failures
            await MainActor.run {
                self?.finishFEXImport(plan, options: options, added: added, containerRecords: mapping, failures: failed)
            }
        }
    }

    private func finishFEXImport(_ plan: FEXImportPlan, options: FEXImportOptions, added: [FontRecord],
                                 containerRecords: [Int64: [UUID]], failures: [String]) {
        fonts.append(contentsOf: added)

        // Folders and sets, keeping FontExplorer's hierarchy.
        var created: [Int64: UUID] = [:]
        var newSets: [(item: FEXSourceItem, set: FontSet)] = []
        var programFolderID: UUID? = nil
        for item in plan.library.items {
            var fontIDs: [UUID] = []
            var seen = Set<UUID>()
            for containerID in item.containerIDs {
                for id in containerRecords[containerID] ?? [] where seen.insert(id).inserted {
                    fontIDs.append(id)
                }
            }
            let isFolder = item.type == FEXSourceItem.typeFolder
            let fallbackName = item.applicationPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "Set"
            let set = FontSet(name: item.title.isEmpty ? fallbackName : item.title, fontIDs: isFolder ? [] : fontIDs,
                              isFolder: isFolder, applicationPath: item.applicationPath)
            created[item.serialID] = set.id
            newSets.append((item, set))
        }
        if newSets.contains(where: { $0.item.type == FEXSourceItem.typeApplicationSet }) {
            let folder = FontSet(name: uniqueSetName("Programm-Sets", parent: nil), isFolder: true)
            programFolderID = folder.id
            sets.append(folder)
        }
        for entry in newSets {
            var set = entry.set
            if entry.item.type == FEXSourceItem.typeApplicationSet {
                set.parentID = programFolderID
            } else {
                set.parentID = created[entry.item.parentSerialID]
            }
            sets.append(set)
        }
        // Names only need to be unique within the same folder.
        for entry in newSets {
            guard let index = sets.firstIndex(where: { $0.id == entry.set.id }) else { continue }
            let name = sets[index].name
            let parent = sets[index].parentID
            if sets.contains(where: { $0.id != entry.set.id && $0.parentID == parent && $0.name == name }) {
                sets[index].name = uniqueSetName(name, parent: parent)
            }
        }

        importProgress = nil
        scheduleSave()
        refreshActivationStates()

        var activation: (changed: Int, failures: [String]) = (0, [])
        if options.restoreActivation {
            let activeIDs = Set(plan.importable.filter(\.isActive).flatMap { containerRecords[$0.id] ?? [] })
            if !activeIDs.isEmpty { activation = activate(activeIDs, scope: .persistent) }
        }

        let folders = newSets.filter { $0.item.type == FEXSourceItem.typeFolder }.count
        let regularSets = newSets.count - folders
        var lines = [
            "\(added.count) Schriften aus \(plan.importable.count - failures.count) Dateien übernommen.",
            "\(regularSets) Sets und \(folders) Ordner übernommen.",
        ]
        if options.restoreActivation {
            lines.append("\(activation.changed) Dateien wie in FontExplorer dauerhaft aktiviert.")
        }
        if plan.skippedSystem + plan.skippedAdobe > 0 {
            lines.append("Nicht übernommen: \(plan.skippedSystem) Systemschriften und \(plan.skippedAdobe) Adobe Fonts; diese verwalten macOS bzw. Creative Cloud.")
        }
        if !plan.missing.isEmpty {
            lines.append("\(plan.missing.count) Dateien aus der FontExplorer-Bibliothek wurden nicht gefunden.")
        }
        if !failures.isEmpty {
            lines.append("\(failures.count) Dateien konnten nicht gelesen oder kopiert werden: " + failures.prefix(5).joined(separator: ", ") + (failures.count > 5 ? " …" : ""))
        }
        if !activation.failures.isEmpty {
            lines.append("\(activation.failures.count) Dateien liessen sich nicht aktivieren.")
        }
        if plan.library.smartSetCount > 0 {
            lines.append("\(plan.library.smartSetCount) Smart Sets wurden nicht übernommen.")
        }
        message = "FontExplorer-Import abgeschlossen."
        infoAlert = InfoAlert(title: "FontExplorer-Bibliothek übernommen", text: lines.joined(separator: "\n\n"))
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

    // MARK: - Sets and folders

    func childSets(of parentID: UUID?) -> [FontSet] {
        sets.filter { $0.parentID == parentID }.sorted { lhs, rhs in
            if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func descendantIDs(of id: UUID) -> Set<UUID> {
        var result = Set<UUID>()
        var queue = [id]
        while let current = queue.popLast() {
            for child in sets where child.parentID == current && result.insert(child.id).inserted {
                queue.append(child.id)
            }
        }
        return result
    }

    /// Fonts of a set; for a folder, the fonts of every set inside it.
    func fontIDs(inSet setID: UUID) -> Set<UUID> {
        guard let set = set(withID: setID) else { return [] }
        guard set.isFolder else { return Set(set.fontIDs) }
        let inside = descendantIDs(of: setID)
        return Set(sets.filter { inside.contains($0.id) && !$0.isFolder }.flatMap(\.fontIDs))
    }

    func set(withID id: UUID) -> FontSet? {
        sets.first { $0.id == id }
    }

    /// "Folder › Set" for menus.
    func displayPath(of set: FontSet) -> String {
        var names = [set.name]
        var parent = set.parentID
        var guardCount = 0
        while let id = parent, let folder = self.set(withID: id), guardCount < 20 {
            names.insert(folder.name, at: 0)
            parent = folder.parentID
            guardCount += 1
        }
        return names.joined(separator: " › ")
    }

    var regularSetsByPath: [FontSet] {
        sets.filter { !$0.isFolder }.sorted {
            displayPath(of: $0).localizedStandardCompare(displayPath(of: $1)) == .orderedAscending
        }
    }

    var foldersByPath: [FontSet] {
        sets.filter(\.isFolder).sorted {
            displayPath(of: $0).localizedStandardCompare(displayPath(of: $1)) == .orderedAscending
        }
    }

    @discardableResult
    func createSet(named name: String, with ids: Set<UUID> = [], in parentID: UUID? = nil) -> UUID {
        let set = FontSet(name: uniqueSetName(name, parent: parentID),
                          fontIDs: fonts.filter { ids.contains($0.id) }.map(\.id),
                          parentID: parentID)
        sets.append(set)
        scheduleSave()
        return set.id
    }

    @discardableResult
    func createFolder(named name: String, in parentID: UUID? = nil) -> UUID {
        let folder = FontSet(name: uniqueSetName(name, parent: parentID), parentID: parentID, isFolder: true)
        sets.append(folder)
        scheduleSave()
        return folder.id
    }

    private func uniqueSetName(_ name: String, parent: UUID?) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let base = trimmed.isEmpty ? "Neues Set" : trimmed
        var candidate = base
        var counter = 2
        while sets.contains(where: { $0.parentID == parent && $0.name == candidate }) {
            candidate = "\(base) \(counter)"
            counter += 1
        }
        return candidate
    }

    func renameSet(_ id: UUID, to name: String) {
        guard let index = sets.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != sets[index].name else { return }
        sets[index].name = uniqueSetName(trimmed, parent: sets[index].parentID)
        scheduleSave()
    }

    /// Moves a set or folder into another folder (nil = top level).
    func moveSet(_ id: UUID, to parentID: UUID?) {
        guard let index = sets.firstIndex(where: { $0.id == id }) else { return }
        if let parentID {
            guard parentID != id, !descendantIDs(of: id).contains(parentID),
                  set(withID: parentID)?.isFolder == true else { return }
        }
        sets[index].parentID = parentID
        sets[index].name = uniqueSetName(sets[index].name, parent: parentID)
        scheduleSave()
    }

    /// Deletes a set. Deleting a folder keeps its contents and moves them
    /// one level up.
    func deleteSet(_ id: UUID) {
        guard let set = set(withID: id) else { return }
        if set.isFolder {
            for index in sets.indices where sets[index].parentID == id {
                sets[index].parentID = set.parentID
            }
        }
        sets.removeAll { $0.id == id }
        scheduleSave()
    }

    func add(_ ids: Set<UUID>, toSet setID: UUID) {
        guard let index = sets.firstIndex(where: { $0.id == setID }), !sets[index].isFolder else { return }
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
}
