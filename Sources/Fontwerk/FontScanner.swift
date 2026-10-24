import Foundation
import CoreText

/// Metadata read from one face of a font file.
struct ScannedFace {
    var postScriptName: String
    var fullName: String
    var familyName: String
    var styleName: String
    var format: String
    var version: String?
    var foundry: String?
    var glyphCount: Int
    var faceIndex: Int
    var fileSize: Int64
    var weight: Double
    var width: Double
    var slant: Double
    var isItalic: Bool
    var axes: [VariationAxis]

    var duplicateKey: String { "\(postScriptName)|\(version ?? "")" }
}

enum FontScanner {
    static let fontExtensions: Set<String> = ["ttf", "otf", "ttc", "otc", "dfont", "woff", "woff2"]

    /// Expands files and folders into a flat list of font files.
    static func collectFontFiles(in urls: [URL]) -> [URL] {
        var result: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                guard let enumerator = fm.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }
                for case let file as URL in enumerator where isFontFile(file) {
                    result.append(file)
                }
            } else if isFontFile(url) {
                result.append(url)
            }
        }
        return result
    }

    static func isFontFile(_ url: URL) -> Bool {
        fontExtensions.contains(url.pathExtension.lowercased())
    }

    /// Reads every face in a font file without registering it.
    static func scan(_ url: URL) -> [ScannedFace] {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              !descriptors.isEmpty else { return [] }
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)

        return descriptors.enumerated().map { (index, descriptor) -> ScannedFace in
            let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
            let formatNumber = (CTFontDescriptorCopyAttribute(descriptor, kCTFontFormatAttribute) as? NSNumber)?.uint32Value ?? 0
            let traits = CTFontCopyTraits(font) as NSDictionary
            let symbolic = (traits[kCTFontSymbolicTrait] as? NSNumber)?.uint32Value ?? 0
            return ScannedFace(
                postScriptName: CTFontCopyPostScriptName(font) as String,
                fullName: CTFontCopyFullName(font) as String,
                familyName: CTFontCopyFamilyName(font) as String,
                styleName: (CTFontCopyName(font, kCTFontStyleNameKey) as String?) ?? "",
                format: formatName(formatNumber, fileExtension: url.pathExtension),
                version: CTFontCopyName(font, kCTFontVersionNameKey) as String?,
                foundry: CTFontCopyName(font, kCTFontManufacturerNameKey) as String?,
                glyphCount: CTFontGetGlyphCount(font),
                faceIndex: index,
                fileSize: size,
                weight: (traits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0,
                width: (traits[kCTFontWidthTrait] as? NSNumber)?.doubleValue ?? 0,
                slant: (traits[kCTFontSlantTrait] as? NSNumber)?.doubleValue ?? 0,
                isItalic: symbolic & CTFontSymbolicTraits.traitItalic.rawValue != 0,
                axes: variationAxes(of: font)
            )
        }
    }

    static func variationAxes(of font: CTFont) -> [VariationAxis] {
        guard let list = CTFontCopyVariationAxes(font) as? [[String: Any]] else { return [] }
        return list.compactMap { axis in
            guard let identifier = (axis[kCTFontVariationAxisIdentifierKey as String] as? NSNumber)?.uint32Value,
                  let minValue = (axis[kCTFontVariationAxisMinimumValueKey as String] as? NSNumber)?.doubleValue,
                  let maxValue = (axis[kCTFontVariationAxisMaximumValueKey as String] as? NSNumber)?.doubleValue,
                  maxValue > minValue else { return nil }
            let defaultValue = (axis[kCTFontVariationAxisDefaultValueKey as String] as? NSNumber)?.doubleValue ?? minValue
            return VariationAxis(
                identifier: identifier,
                tag: VariationAxis.tagString(identifier),
                name: axis[kCTFontVariationAxisNameKey as String] as? String ?? "",
                minValue: minValue,
                maxValue: maxValue,
                defaultValue: defaultValue
            )
        }
    }

    static func formatName(_ raw: UInt32, fileExtension: String) -> String {
        let ext = fileExtension.lowercased()
        if ext == "woff" { return "WOFF" }
        if ext == "woff2" { return "WOFF2" }
        switch raw {
        case 1: return "OpenType PS"
        case 2: return "OpenType TT"
        case 3: return "TrueType"
        case 4: return "PostScript"
        case 5: return "Bitmap"
        default: return ext.uppercased()
        }
    }

    /// Copies a font file into the managed library folder, sorted by
    /// the first letter of the family name. Never overwrites a file.
    static func copyIntoLibrary(_ file: URL, familyName: String, root: URL) throws -> URL {
        let fm = FileManager.default
        let first = familyName.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "#"
        let bucket = first.rangeOfCharacter(from: .letters) != nil ? first : "#"
        let folder = root.appendingPathComponent(bucket, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let base = file.deletingPathExtension().lastPathComponent
        let ext = file.pathExtension
        var target = folder.appendingPathComponent(file.lastPathComponent)
        var counter = 2
        while fm.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(base) \(counter)").appendingPathExtension(ext)
            counter += 1
        }
        try fm.copyItem(at: file, to: target)
        return target
    }

    /// Copies the whole folder that contains a font, so companion files
    /// (PostScript outlines, metrics, resource forks) stay together.
    /// FontExplorer keeps every font file in a folder of its own.
    /// Each source folder is copied only once.
    static func copyFolderIntoLibrary(containing file: URL, familyName: String, root: URL,
                                      copiedFolders: inout [String: URL]) throws -> URL {
        let sourceFolder = file.deletingLastPathComponent()
        if let existing = copiedFolders[sourceFolder.path] {
            return existing.appendingPathComponent(file.lastPathComponent)
        }
        let fm = FileManager.default
        let first = familyName.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "#"
        let bucket = first.rangeOfCharacter(from: .letters) != nil ? first : "#"
        let bucketFolder = root.appendingPathComponent(bucket, isDirectory: true)
        try fm.createDirectory(at: bucketFolder, withIntermediateDirectories: true)

        let baseName = sourceFolder.lastPathComponent
        var target = bucketFolder.appendingPathComponent(baseName, isDirectory: true)
        var counter = 2
        while fm.fileExists(atPath: target.path) {
            target = bucketFolder.appendingPathComponent("\(baseName) \(counter)", isDirectory: true)
            counter += 1
        }
        try fm.copyItem(at: sourceFolder, to: target)
        copiedFolders[sourceFolder.path] = target
        return target.appendingPathComponent(file.lastPathComponent)
    }
}

/// Creates fonts for previews straight from the file, so inactive
/// fonts can be shown without activating them.
final class FontFaceCache {
    static let shared = FontFaceCache()
    private var descriptors: [String: CTFontDescriptor] = [:]
    private let lock = NSLock()

    func font(for record: FontRecord, size: CGFloat) -> CTFont? {
        guard let descriptor = descriptor(for: record) else { return nil }
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    /// A variable font with chosen axis values (keyed by axis tag).
    func font(for record: FontRecord, size: CGFloat, variation: [String: Double]) -> CTFont? {
        guard var descriptor = self.descriptor(for: record) else { return nil }
        for axis in record.axes ?? [] {
            guard let value = variation[axis.tag] else { continue }
            let clamped = min(max(value, axis.minValue), axis.maxValue)
            descriptor = CTFontDescriptorCreateCopyWithVariation(
                descriptor, NSNumber(value: axis.identifier) as CFNumber, CGFloat(clamped))
        }
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    func descriptor(for record: FontRecord) -> CTFontDescriptor? {
        let key = "\(record.fileURL.path)#\(record.faceIndex)"
        lock.lock()
        if let cached = descriptors[key] { lock.unlock(); return cached }
        lock.unlock()

        guard let all = CTFontManagerCreateFontDescriptorsFromURL(record.fileURL as CFURL) as? [CTFontDescriptor],
              !all.isEmpty else { return nil }
        var match: CTFontDescriptor? = nil
        if record.faceIndex < all.count {
            let candidate = all[record.faceIndex]
            let name = CTFontDescriptorCopyAttribute(candidate, kCTFontNameAttribute) as? String
            if name == nil || name == record.postScriptName { match = candidate }
        }
        if match == nil {
            match = all.first { (CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String) == record.postScriptName }
        }
        let result = match ?? all[0]
        lock.lock()
        descriptors[key] = result
        lock.unlock()
        return result
    }

    func clear() {
        lock.lock()
        descriptors.removeAll()
        lock.unlock()
    }
}
