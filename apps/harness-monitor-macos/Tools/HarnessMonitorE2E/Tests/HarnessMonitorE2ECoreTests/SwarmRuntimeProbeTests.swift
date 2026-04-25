import XCTest
@testable import HarnessMonitorE2ECore

final class SwarmRuntimeProbeTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("swarm-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempHome)
    }

    func testMissingRequiredBinariesAreReported() {
        let probe = SwarmRuntimeProbe(
            environment: [:],
            homeDirectory: tempHome,
            commandLocator: { _ in nil },
            commandRunner: { _, _, _ in
                XCTFail("runner should not be called when binaries are missing")
                return .init(exitStatus: 127, stdout: Data(), stderr: Data())
            }
        )

        let report = probe.run()

        XCTAssertEqual(report.requiredMissing, ["claude", "codex"])
        XCTAssertEqual(report.runtimes["claude"]?.reason, "binary 'claude' not found")
        XCTAssertEqual(report.runtimes["codex"]?.reason, "binary 'codex' not found")
        XCTAssertFalse(report.runtimes["copilot"]?.required ?? true)
    }

    func testAuthenticatedVersionedRuntimesBecomeAvailable() throws {
        let codexAuthPath = tempHome.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(
            at: codexAuthPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: codexAuthPath)

        let probe = SwarmRuntimeProbe(
            environment: [:],
            homeDirectory: tempHome,
            commandLocator: { name in "/usr/bin/\(name)" },
            commandRunner: { executable, arguments, _ in
                let invocation = ([URL(fileURLWithPath: executable).lastPathComponent] + arguments)
                    .joined(separator: " ")
                switch invocation {
                case "claude auth status":
                    return .init(exitStatus: 0, stdout: Data(#"{"loggedIn":true}"#.utf8), stderr: Data())
                case "claude --version", "codex --version", "gemini --version", "vibe --version", "opencode --version":
                    return .init(exitStatus: 0, stdout: Data("ok".utf8), stderr: Data())
                default:
                    return .init(exitStatus: 0, stdout: Data(), stderr: Data())
                }
            }
        )

        let report = probe.run()

        XCTAssertTrue(report.runtimes["claude"]?.available ?? false)
        XCTAssertTrue(report.runtimes["codex"]?.available ?? false)
        XCTAssertEqual(report.requiredMissing, [])
    }
}
