import XCTest
@testable import ViewerCore

final class CommandRunnerTests: XCTestCase {
    func testInheritedPipeDoesNotDefeatTimeout() throws {
        let start = ProcessInfo.processInfo.systemUptime
        let result = try CommandRunner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 2 & wait"], timeout: 0.1)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
    }

    func testDrainsOutputLargerThanPipeBuffer() throws {
        let result = try CommandRunner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "i=0; while [ \"$i\" -lt 5000 ]; do printf abcdefghijklmnopqrstuvwxyz0123456789; i=$((i+1)); done"], timeout: 5)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output.count, 180_000)
    }

    func testClosedOutputDoesNotDefeatTimeout() throws {
        let start = ProcessInfo.processInfo.systemUptime
        let result = try CommandRunner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exec 1>&- 2>&-; exec sleep 2"], timeout: 0.1)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
    }
}
