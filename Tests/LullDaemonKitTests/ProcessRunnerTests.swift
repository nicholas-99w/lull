import XCTest

@testable import LullDaemonKit

final class ProcessRunnerTests: XCTestCase {
    func testOutputReturnsStatusAndStdout() {
        let r = ProcessRunner().output("/bin/echo", ["hello"], timeout: 5)
        XCTAssertEqual(r?.status, 0)
        XCTAssertEqual(r?.stdout, "hello\n")
    }

    /// A hung tool must not block the command queue (and the sleep fallback
    /// queued behind it) past its timeout.
    func testOutputTimesOutOnHungChild() {
        let start = Date()
        XCTAssertNil(ProcessRunner().output("/bin/sleep", ["10"], timeout: 0.5))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testRunTimesOutOnHungChild() {
        let start = Date()
        XCTAssertNil(ProcessRunner().run("/bin/sleep", ["10"], timeout: 0.5))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
}
