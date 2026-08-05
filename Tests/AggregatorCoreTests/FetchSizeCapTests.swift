import XCTest
@testable import AggregatorCore

/// Finding 3e (pre-publish review): response-size caps. A runaway or hostile response must
/// never buffer without bound on the CI runner -- pages/feeds cap at 10MB, images at 30MB,
/// both far above anything a legitimate source serves. The cap decisions are pure functions
/// (`SizeCap`) so they're testable without a live server; the streaming abort itself lives in
/// `SizeCapSessionDelegate` and the compiler-level behavior is covered in
/// `EditionCompilerTests`.
final class FetchSizeCapTests: XCTestCase {

    func testLimitValues() {
        XCTAssertEqual(FetchLimits.pageBytes, 10 * 1024 * 1024)
        XCTAssertEqual(FetchLimits.imageBytes, 30 * 1024 * 1024)
    }

    // MARK: - Declared Content-Length (abort before the body arrives)

    func testDeclaredLengthOverLimitAborts() {
        XCTAssertTrue(SizeCap.declaredLengthExceeds(limit: 100, declared: 101))
    }

    func testDeclaredLengthAtOrUnderLimitAllows() {
        XCTAssertFalse(SizeCap.declaredLengthExceeds(limit: 100, declared: 100))
        XCTAssertFalse(SizeCap.declaredLengthExceeds(limit: 100, declared: 1))
    }

    func testUnknownDeclaredLengthNeverAbortsUpFront() {
        // -1 is URLResponse's "unknown" sentinel; 0 is an empty body. Neither may abort --
        // the streaming check covers an undeclared oversize body.
        XCTAssertFalse(SizeCap.declaredLengthExceeds(limit: 100, declared: -1))
        XCTAssertFalse(SizeCap.declaredLengthExceeds(limit: 100, declared: 0))
    }

    func testNilLimitMeansUncapped() {
        XCTAssertFalse(SizeCap.declaredLengthExceeds(limit: nil, declared: .max))
        XCTAssertFalse(SizeCap.accumulatedExceeds(limit: nil, count: Int.max))
    }

    // MARK: - Streaming accumulation (abort mid-flight)

    func testAccumulatedOverLimitAborts() {
        XCTAssertTrue(SizeCap.accumulatedExceeds(limit: 100, count: 101))
    }

    func testAccumulatedAtLimitAllows() {
        XCTAssertFalse(SizeCap.accumulatedExceeds(limit: 100, count: 100))
    }
}
