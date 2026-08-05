import XCTest
@testable import AggregatorCore

/// Finding 3d (pre-publish review): `ProcessRunner.run` used to read stdout to EOF before
/// touching stderr. A tool that writes more than the ~64KB pipe buffer to stderr while its
/// stdout is still open then deadlocks: the tool blocks on the full stderr pipe, so its stdout
/// never reaches EOF, so the parent never starts draining stderr. Both pipes must drain
/// concurrently. These tests use a real child process pushing well past the pipe buffer on
/// BOTH streams -- under the old implementation they hang forever instead of failing.
final class ProcessRunnerPipeTests: XCTestCase {

    /// 200KB on each stream -- 3x the pipe buffer, so a sequential reader deadlocks.
    func testLargeStdoutAndStderrBothDrainWithoutDeadlock() throws {
        let result = try ProcessRunner.run([
            "/bin/sh", "-c",
            "head -c 200000 /dev/zero; head -c 200000 /dev/zero 1>&2"
        ])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.count, 200_000)
        XCTAssertEqual(result.stderr.count, 200_000)
    }

    /// The nastier interleaving: stderr fills FIRST, while stdout still has bytes coming --
    /// exactly the shape that blocked the old stdout-first read order.
    func testStderrSpamBeforeStdoutCompletes() throws {
        let result = try ProcessRunner.run([
            "/bin/sh", "-c",
            "head -c 200000 /dev/zero 1>&2; head -c 100000 /dev/zero"
        ])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.count, 100_000)
        XCTAssertEqual(result.stderr.count, 200_000)
    }

    /// Content integrity: distinct bytes per stream land on the right sides.
    func testStreamsAreNotCrossed() throws {
        let result = try ProcessRunner.run([
            "/bin/sh", "-c",
            "printf out-side; printf err-side 1>&2"
        ])
        XCTAssertEqual(result.stdoutText, "out-side")
        XCTAssertEqual(result.stderrText, "err-side")
    }
}
