import Foundation

enum GzipError: Error {
    case commandFailed(status: Int32, stderr: String)
    case outputMissing
}

/// Gzip via the system `gzip` binary (present on both macOS and the Ubuntu runners) --
/// Foundation has no gzip API on Linux and a compression dependency isn't worth one file.
/// `-n` omits the original name/timestamp from the header (deterministic output for identical
/// input); `-9` maximum compression (this runs twice an hour on a CI box, not a phone).
enum GzipWriter {
    static func writeGzipped(_ data: Data, to outputURL: URL) throws {
        let tempDir = FileManager.default.temporaryDirectory
        let stem = tempDir.appendingPathComponent("broadsheet-gz-\(UUID().uuidString)")
        let plainURL = stem.appendingPathExtension("json")
        try data.write(to: plainURL)
        defer {
            try? FileManager.default.removeItem(at: plainURL)
        }
        let result = try ProcessRunner.run(["gzip", "-n", "-9", "-f", plainURL.path])
        guard result.status == 0 else {
            throw GzipError.commandFailed(status: result.status, stderr: result.stderrText)
        }
        let gzURL = plainURL.appendingPathExtension("gz")
        guard FileManager.default.fileExists(atPath: gzURL.path) else {
            throw GzipError.outputMissing
        }
        try? FileManager.default.removeItem(at: outputURL)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: gzURL, to: outputURL)
    }
}
