import Foundation
import CoreText

struct ActivationFailure: LocalizedError {
    let file: String
    var errorDescription: String? { "\(file) konnte nicht verarbeitet werden." }
}

/// Thin wrapper around the CoreText font manager. Activation always
/// works on whole files, because macOS registers files, not faces.
enum ActivationService {
    static func scope(for state: ActivationState) -> CTFontManagerScope {
        state == .persistent ? .persistent : .session
    }

    static func register(_ url: URL, as state: ActivationState) throws {
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, scope(for: state), &error) { return }
        if let cfError = error?.takeRetainedValue() {
            if CFErrorGetCode(cfError) == CTFontManagerError.alreadyRegistered.rawValue { return }
            throw cfError
        }
        throw ActivationFailure(file: url.lastPathComponent)
    }

    /// Removes the file's registration in every scope, so a registration
    /// that was made in a different scope than recorded is removed too.
    /// Returns true if at least one scope actually held the file.
    @discardableResult
    static func unregisterEverywhere(_ url: URL) throws -> Bool {
        var removed = false
        var realError: Error? = nil
        for scope in [CTFontManagerScope.persistent, .session, .process] {
            var error: Unmanaged<CFError>?
            if CTFontManagerUnregisterFontsForURL(url as CFURL, scope, &error) {
                removed = true
                continue
            }
            if let cfError = error?.takeRetainedValue(),
               CFErrorGetCode(cfError) != CTFontManagerError.notRegistered.rawValue {
                realError = cfError
            }
        }
        if !removed, let realError { throw realError }
        return removed
    }

    /// Paths of every font file macOS currently makes available.
    static func availableFontPaths() -> Set<String> {
        guard let urls = CTFontManagerCopyAvailableFontURLs() as? [URL] else { return [] }
        return Set(urls.map { normalizedPath($0) })
    }

    /// Every file from which macOS currently provides a face with this
    /// PostScript name.
    static func activeLocations(ofPostScriptName name: String) -> [URL] {
        let wanted = CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: name] as CFDictionary)
        let mandatory = NSSet(object: kCTFontNameAttribute as String) as CFSet
        guard let matches = CTFontDescriptorCreateMatchingFontDescriptors(wanted, mandatory) as? [CTFontDescriptor] else {
            return []
        }
        var seen = Set<String>()
        var result: [URL] = []
        for match in matches {
            guard let url = CTFontDescriptorCopyAttribute(match, kCTFontURLAttribute) as? URL else { continue }
            if seen.insert(normalizedPath(url)).inserted { result.append(url) }
        }
        return result
    }

    static let macOSFontFolders: [String] = [
        NSHomeDirectory() + "/Library/Fonts",
        "/Library/Fonts",
        "/System/Library/Fonts",
        "/System/Library/AssetsV2",
        "/Network/Library/Fonts",
    ]

    static func isInMacOSFontFolder(_ url: URL) -> Bool {
        let path = normalizedPath(url)
        return macOSFontFolders.contains { path.hasPrefix(($0 as NSString).resolvingSymlinksInPath + "/") }
    }

    static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func displayPath(_ url: URL) -> String {
        (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }
}
