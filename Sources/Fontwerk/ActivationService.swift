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

    static func unregister(_ url: URL, from state: ActivationState) throws {
        guard state != .inactive else { return }
        var error: Unmanaged<CFError>?
        if CTFontManagerUnregisterFontsForURL(url as CFURL, scope(for: state), &error) { return }
        if let cfError = error?.takeRetainedValue() {
            if CFErrorGetCode(cfError) == CTFontManagerError.notRegistered.rawValue { return }
            throw cfError
        }
        throw ActivationFailure(file: url.lastPathComponent)
    }

    /// Paths of every font file macOS currently makes available.
    static func availableFontPaths() -> Set<String> {
        guard let urls = CTFontManagerCopyAvailableFontURLs() as? [URL] else { return [] }
        return Set(urls.map { normalizedPath($0) })
    }

    static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
