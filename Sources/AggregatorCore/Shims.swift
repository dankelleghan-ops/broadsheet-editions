import Foundation

// MARK: - App-symbol shims
//
// The vendored pipeline sources (Sources/AggregatorCore/Vendored/, copied byte-for-byte from
// Broadsheet/ by sync-shared-sources.sh) reference two app-side singletons. These shims
// provide the SYMBOLS those files need to compile -- never alternative pipeline logic. Keep
// each one the minimal surface the vendored files actually touch, so any new app-side use
// surfaces as a compile error here rather than silently diverging.

/// Shim for the app's `Prefs` (Broadsheet/App/Prefs.swift). The only member the vendored
/// sources read is `englishOnlyArticles` -- `ArticleGate.evaluate`'s default argument. The
/// app defaults this preference to `true` (Prefs.swift: `?? true`), and the edition contract
/// makes LanguageFilter a server-side responsibility, so the compiler keeps it on. (On Linux
/// only the structural la-voz rule runs -- see Vendored/LanguageFilter.swift -- and the phone
/// re-applies its full filter on ingest.)
final class Prefs {
    static let shared = Prefs()
    var englishOnlyArticles: Bool = true
}

/// Log levels matching the app's `DiagnosticsLog` API (Broadsheet/Support/DiagnosticsLog.swift).
enum LogLevel: String {
    case info, warn, error
}

/// Shim for the app's `DiagnosticsLog`: same `log(_:source:_:)` signature, but writes straight
/// to stderr (this is a CLI -- the GitHub Actions log IS the diagnostics surface). Also counts
/// per-level totals so the run summary can report them.
final class DiagnosticsLog: @unchecked Sendable {
    static let shared = DiagnosticsLog()

    private let lock = NSLock()
    private(set) var warnCount = 0
    private(set) var errorCount = 0
    /// Quiet mode for unit tests (vendored ContentExtractor logs on some fixture inputs).
    var isSilenced = false

    func log(_ level: LogLevel, source: String?, _ message: String) {
        lock.lock()
        if level == .warn { warnCount += 1 }
        if level == .error { errorCount += 1 }
        let silenced = isSilenced
        lock.unlock()
        guard !silenced else { return }
        FileHandle.standardError.write(Data("[\(level.rawValue)] \(source ?? "-"): \(message)\n".utf8))
    }
}
