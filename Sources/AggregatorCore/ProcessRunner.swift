import Foundation

struct ProcessResult {
    let status: Int32
    let stdout: Data
    let stderr: Data

    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

enum ProcessRunnerError: Error {
    case executableNotFound(String)
}

/// Small Process wrapper for the shell-outs this package needs (image resize via
/// ImageMagick/sips, gzip). Linux + macOS.
enum ProcessRunner {
    /// Resolves a bare tool name against PATH (no subprocess -- a manual PATH scan, portable
    /// and testable). Absolute paths are returned as-is when executable.
    static func findExecutable(_ name: String,
                              environmentPATH: String? = ProcessInfo.processInfo.environment["PATH"]) -> String? {
        let fm = FileManager.default
        if name.contains("/") {
            return fm.isExecutableFile(atPath: name) ? name : nil
        }
        for dir in (environmentPATH ?? "").split(separator: ":") {
            let candidate = String(dir) + "/" + name
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    @discardableResult
    static func run(_ argv: [String]) throws -> ProcessResult {
        precondition(!argv.isEmpty)
        guard let executable = findExecutable(argv[0]) else {
            throw ProcessRunnerError.executableNotFound(argv[0])
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(argv.dropFirst())
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        // Finding 3d: drain BOTH pipes concurrently, before waitUntilExit. Reading stdout to
        // EOF first deadlocks when the tool writes more than the ~64KB pipe buffer to stderr
        // while its stdout is still open: the tool blocks on the full stderr pipe, so stdout
        // never reaches EOF, so stderr never gets read. A background thread drains stderr
        // while this thread drains stdout; the semaphore is the completion barrier (and the
        // memory barrier for `stderrData`).
        let errHandle = errPipe.fileHandleForReading
        var stderrData = Data()
        let stderrDrained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            stderrData = errHandle.readDataToEndOfFile()
            stderrDrained.signal()
        }
        let stdout = outPipe.fileHandleForReading.readDataToEndOfFile()
        stderrDrained.wait()
        process.waitUntilExit()
        return ProcessResult(status: process.terminationStatus, stdout: stdout, stderr: stderrData)
    }
}
