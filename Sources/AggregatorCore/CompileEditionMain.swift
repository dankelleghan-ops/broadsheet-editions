import Foundation

/// CLI entry point for the `compile-edition` executable.
///
///     swift run compile-edition --out <dir> [--base-url URL] [--state FILE] [--window-hours N]
///
/// Defaults: base URL is a placeholder (the publish phase sets the real GitHub Pages URL),
/// state file sits NEXT TO the output directory (never inside it -- the out dir is what gets
/// force-pushed to gh-pages; the state file is cached separately by the workflow).
public enum CompileEditionMain {
    struct Arguments {
        var outDirectory: URL
        var baseURL: String
        var stateFileURL: URL
        var windowHours: Int
    }

    enum ArgumentError: Error, Equatable {
        case missingOut
        case missingValue(String)
        case unknownFlag(String)
        case invalidWindowHours(String)
    }

    static func parseArguments(_ raw: [String]) throws -> Arguments {
        var out: String?
        var baseURL = "https://example.invalid/broadsheet-edition"
        var state: String?
        var windowHours = 48

        var index = 0
        while index < raw.count {
            let flag = raw[index]
            func value() throws -> String {
                index += 1
                guard index < raw.count else { throw ArgumentError.missingValue(flag) }
                return raw[index]
            }
            switch flag {
            case "--out": out = try value()
            case "--base-url": baseURL = try value()
            case "--state": state = try value()
            case "--window-hours":
                let text = try value()
                guard let hours = Int(text), hours > 0 else { throw ArgumentError.invalidWindowHours(text) }
                windowHours = hours
            default: throw ArgumentError.unknownFlag(flag)
            }
            index += 1
        }
        guard let outPath = out else { throw ArgumentError.missingOut }
        let outURL = URL(fileURLWithPath: outPath, isDirectory: true).standardizedFileURL
        let stateURL = state.map { URL(fileURLWithPath: $0).standardizedFileURL }
            ?? outURL.deletingLastPathComponent()
                .appendingPathComponent(outURL.lastPathComponent + "-state.json")
        return Arguments(outDirectory: outURL, baseURL: baseURL, stateFileURL: stateURL,
                         windowHours: windowHours)
    }

    public static func run() async {
        let arguments: Arguments
        do {
            arguments = try parseArguments(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("""
            compile-edition: \(error)
            usage: compile-edition --out <dir> [--base-url URL] [--state FILE] [--window-hours N]

            """.utf8))
            exit(2)
        }

        let resizer: ToolImageResizer
        do {
            resizer = try ToolImageResizer()
        } catch {
            FileHandle.standardError.write(Data(
                "compile-edition: no image tool found (need ImageMagick `magick`/`convert`, or `sips` on macOS)\n".utf8))
            exit(3)
        }

        let compiler = EditionCompiler(
            catalog: SourceCatalog.all,
            client: Fetcher(),
            resizer: resizer,
            configuration: CompilerConfiguration(
                baseURL: arguments.baseURL,
                outDirectory: arguments.outDirectory,
                stateFileURL: arguments.stateFileURL,
                windowHours: arguments.windowHours
            )
        )

        do {
            let stats = try await compiler.run()
            print(report(stats))
            // Hard-exit the success path (2026-08-23). Returning normally from here releases
            // `compiler` -> its `client` -> the single live `Fetcher` -> `Fetcher.deinit`'s
            // `session.finishTasksAndInvalidate()`. On Linux that starts corelibs-foundation's
            // libcurl multi-handle teardown (`curl_multi_cleanup` -> libssl/libcrypto) on a
            // worker thread at the same moment the process's own exit sequence is running
            // atexit handlers -- including OpenSSL's, which tears down the very global crypto
            // state the curl thread is still walking. Two teardowns racing over one set of
            // globals; it lost on 2026-08-22 (run 32604568905: SIGSEGV, "Bad pointer
            // dereference at 0x18", crashing thread mid-`URLSession._MultiHandle.deinit`).
            //
            // That crash cost a whole edition for nothing: the report below had already
            // printed and edition.json.gz, the images and the state file were all on disk.
            // The process died on the doorstep, exit code 139, so the publish step never ran.
            //
            // `exit`/`_exit` never return to this scope, so the compiler-inserted release that
            // would run `Fetcher.deinit` is simply never reached -- that removes our side of
            // the race outright. `_exit` rather than `exit` because it also skips atexit
            // handlers, so OpenSSL's own cleanup can't race anything else still in flight.
            // `fflush(nil)` first is mandatory, not belt-and-braces: `_exit` skips stdio
            // flushing, and stdout is FULLY buffered (not line-buffered) whenever it is a pipe
            // rather than a TTY -- which is exactly how GitHub Actions captures it. Without
            // the flush the run report above would be silently discarded.
            //
            // Nothing is lost by exiting hard: every output is written synchronously through
            // Foundation file APIs and re-read to compute the report's own byte counts, well
            // before `compiler.run()` returns. No output depends on a deinit or atexit path.
            fflush(nil)
            _exit(0)
        } catch {
            FileHandle.standardError.write(Data("compile-edition: FAILED: \(error)\n".utf8))
            exit(1)
        }
    }

    static func report(_ stats: RunStats) -> String {
        var lines: [String] = []
        lines.append("=== edition compile report ===")
        for source in stats.perSource.sorted(by: { $0.sourceID < $1.sourceID }) {
            var parts = ["\(source.newArticles) new"]
            if source.eligibleItems != source.newArticles {
                parts.append("\(source.eligibleItems) eligible")
            }
            if source.gateRejected > 0 { parts.append("\(source.gateRejected) gate-rejected") }
            if source.failures > 0 { parts.append("\(source.failures) failures") }
            if source.skippedPreviouslyRejected > 0 { parts.append("\(source.skippedPreviouslyRejected) skipped-prior-rejects") }
            if source.feedsNotModified > 0 { parts.append("\(source.feedsNotModified) feeds 304") }
            if source.feedErrors > 0 { parts.append("\(source.feedErrors) feed errors") }
            if source.imageFailures > 0 { parts.append("\(source.imageFailures) image failures") }
            if source.hitItemCap { parts.append("item cap hit (remainder drains next run)") }
            lines.append("  \(source.sourceID): " + parts.joined(separator: ", "))
        }
        lines.append("articles: \(stats.totalArticles) total (\(stats.newArticles) new + \(stats.retainedArticles) retained)")
        lines.append(String(format: "edition.json.gz: %.2f MB (%d bytes)",
                            Double(stats.gzippedBytes) / 1_048_576, stats.gzippedBytes))
        lines.append(String(format: "images: %d files, %.2f MB (%d pruned this run)",
                            stats.imageCount, Double(stats.imageBytes) / 1_048_576, stats.prunedImageCount))
        lines.append(String(format: "wall clock: %.1fs", stats.wallClockSeconds))
        if stats.budgetTruncated {
            // Finding 3b: not a failure -- the run shipped what it had; the deferred sources'
            // feed conditionals were never committed, so the next run picks them up in full.
            lines.append("BUDGET-TRUNCATED: run budget reached -- \(stats.skippedSourceCount) source(s) deferred to the next run")
        }
        if stats.gzippedBytes > 8 * 1_048_576 {
            lines.append("WARNING: gzipped edition exceeds the ~8MB contract target")
        }
        return lines.joined(separator: "\n")
    }
}
