import SwiftUI
import CoreText

enum PreviewMode: String, CaseIterable, Identifiable {
    case text = "Text"
    case waterfall = "Wasserfall"
    case characters = "Zeichen"
    case info = "Info"
    var id: Self { self }
}

struct PreviewPane: View {
    @EnvironmentObject private var store: LibraryStore
    let fontIDs: Set<UUID>

    @AppStorage("previewText") private var sampleText = "Franz jagt im komplett verwahrlosten Taxi quer durch Bayern"
    @AppStorage("previewSize") private var size = 36.0
    @State private var mode: PreviewMode = .text
    /// Chosen values for variable font axes, by axis tag.
    @State private var axisValues: [String: Double] = [:]

    private var records: [FontRecord] {
        store.records(withIDs: fontIDs).sorted { lhs, rhs in
            if lhs.familyName != rhs.familyName {
                return lhs.familyName.localizedStandardCompare(rhs.familyName) == .orderedAscending
            }
            return FaceOrder.areInOrder(lhs, rhs)
        }
    }

    /// Axes of the selected variable fonts, merged by tag.
    private var variationAxes: [VariationAxis] {
        var result: [VariationAxis] = []
        for record in records where record.isVariable {
            for axis in record.axes ?? [] where !result.contains(where: { $0.tag == axis.tag }) {
                result.append(axis)
            }
        }
        return result
    }

    var body: some View {
        let records = self.records
        if records.isEmpty {
            ContentUnavailableView(
                "Keine Schrift ausgewählt",
                systemImage: "textformat.size",
                description: Text("Wähle eine oder mehrere Schriften aus der Liste.")
            )
        } else {
            VStack(spacing: 0) {
                controls
                Divider()
                ScrollView {
                    content(records)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Ansicht", selection: $mode) {
                ForEach(PreviewMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if mode == .text {
                TextField("Mustertext", text: $sampleText)
                    .textFieldStyle(.roundedBorder)
            }
            if mode == .text || mode == .characters {
                HStack {
                    Image(systemName: "textformat.size.smaller")
                    Slider(value: $size, in: 8...160)
                    Image(systemName: "textformat.size.larger")
                    Text("\(Int(size)) pt").monospacedDigit().frame(width: 50, alignment: .trailing)
                }
            }
            if mode != .info && !variationAxes.isEmpty {
                axisControls
            }
        }
        .padding(12)
        .onChange(of: fontIDs) { _, _ in axisValues = [:] }
    }

    private var axisControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VariableBadge()
                Spacer()
                Button("Zurücksetzen") { axisValues = [:] }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(axisValues.isEmpty)
            }
            ForEach(variationAxes) { axis in
                HStack {
                    Text(axis.displayName)
                        .frame(width: 110, alignment: .leading)
                        .help("Achse \(axis.tag)")
                    Slider(
                        value: Binding(
                            get: { axisValues[axis.tag] ?? axis.defaultValue },
                            set: { axisValues[axis.tag] = $0 }
                        ),
                        in: axis.minValue...axis.maxValue
                    )
                    Text(VariationAxis.format((axisValues[axis.tag] ?? axis.defaultValue).rounded()))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func content(_ records: [FontRecord]) -> some View {
        switch mode {
        case .text:
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(records.prefix(50)) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.fullName).font(.caption).foregroundStyle(.secondary)
                        Text(sampleText.isEmpty ? record.fullName : sampleText)
                            .font(previewFont(record, size: size))
                            .textSelection(.enabled)
                    }
                }
                if records.count > 50 {
                    Text("Nur die ersten 50 von \(records.count) Schriften werden angezeigt.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        case .waterfall:
            let record = records[0]
            VStack(alignment: .leading, spacing: 10) {
                Text(record.fullName).font(.headline)
                ForEach([9, 10, 11, 12, 14, 18, 24, 30, 36, 48, 60, 72], id: \.self) { pt in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(pt)").font(.caption).foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
                        Text(sampleText.isEmpty ? record.fullName : sampleText)
                            .font(previewFont(record, size: Double(pt)))
                            .lineLimit(1)
                    }
                }
            }
        case .characters:
            CharacterGrid(record: records[0], size: size)
        case .info:
            FontInfoView(record: records[0], selectionCount: records.count, ids: fontIDs)
        }
    }

    private func previewFont(_ record: FontRecord, size: Double) -> Font {
        if record.isVariable && !axisValues.isEmpty,
           let ctFont = FontFaceCache.shared.font(for: record, size: CGFloat(size), variation: axisValues) {
            return Font(ctFont)
        }
        if let ctFont = FontFaceCache.shared.font(for: record, size: CGFloat(size)) {
            return Font(ctFont)
        }
        return .system(size: size)
    }
}

struct CharacterGrid: View {
    let record: FontRecord
    let size: Double

    private var characters: [UInt32] {
        guard let font = FontFaceCache.shared.font(for: record, size: 12) else { return [] }
        let set = CTFontCopyCharacterSet(font)
        var result: [UInt32] = []
        var codePoint: UInt32 = 0x20
        while codePoint <= 0x2FFFF && result.count < 4000 {
            if (codePoint < 0xD800 || codePoint > 0xDFFF) && codePoint != 0x7F,
               CFCharacterSetIsLongCharacterMember(set, codePoint) {
                result.append(codePoint)
            }
            codePoint += 1
        }
        return result
    }

    var body: some View {
        let cell = max(36, min(size * 1.4, 120))
        let font: Font = FontFaceCache.shared.font(for: record, size: CGFloat(cell * 0.55)).map { Font($0) } ?? .body
        let chars = characters
        VStack(alignment: .leading, spacing: 8) {
            Text("\(record.fullName) · \(chars.count) Zeichen\(chars.count >= 4000 ? " (gekürzt)" : "")")
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: cell), spacing: 4)], spacing: 4) {
                ForEach(chars, id: \.self) { code in
                    let text = Unicode.Scalar(code).map { String(Character($0)) } ?? "?"
                    Text(text)
                        .font(font)
                        .frame(width: cell, height: cell)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.08)))
                        .help(String(format: "U+%04X", code))
                        .textSelection(.enabled)
                }
            }
        }
    }
}

struct FontInfoView: View {
    @EnvironmentObject private var store: LibraryStore
    let record: FontRecord
    let selectionCount: Int
    let ids: Set<UUID>
    @State private var tagText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if selectionCount > 1 {
                Text("\(selectionCount) Schriften ausgewählt. Bewertung, Favorit und Tags gelten für alle; die Details zeigen die erste.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { star in
                    Button {
                        store.setRating(ids, rating: record.rating == star ? 0 : star)
                    } label: {
                        Image(systemName: star <= record.rating ? "star.fill" : "star")
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                }
                Spacer().frame(width: 16)
                Toggle("Favorit", isOn: Binding(
                    get: { record.isFavorite },
                    set: { store.setFavorite(ids, $0) }
                ))
            }

            HStack {
                TextField("Tags, durch Komma getrennt", text: $tagText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveTags() }
                Button("Sichern") { saveTags() }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                infoRow("Familie", record.familyName)
                infoRow("Stil", record.styleName)
                infoRow("PostScript-Name", record.postScriptName)
                infoRow("Version", record.versionText)
                infoRow("Hersteller", record.foundryText)
                infoRow("Format", record.isVariable ? "\(record.format) · Variable Font" : record.format)
                ForEach(record.axes ?? []) { axis in
                    infoRow("Achse \(axis.displayName)", "\(axis.rangeText) (\(axis.tag))")
                }
                infoRow("Glyphen", "\(record.glyphCount)")
                infoRow("Status", record.isMissing ? "Datei fehlt" : record.activation.label)
                infoRow("Dateigrösse", ByteCountFormatter.string(fromByteCount: record.fileSize, countStyle: .file))
                infoRow("Importiert", record.importedAt.formatted(date: .abbreviated, time: .shortened))
                infoRow("Datei", record.fileURL.path)
            }
            .font(.callout)
        }
        .onAppear { tagText = record.tags.joined(separator: ", ") }
        .onChange(of: record.id) { _, _ in tagText = record.tags.joined(separator: ", ") }
    }

    private func saveTags() {
        store.setTags(ids, tags: tagText.split(separator: ",").map(String.init))
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value.isEmpty ? "–" : value).textSelection(.enabled)
        }
    }
}
