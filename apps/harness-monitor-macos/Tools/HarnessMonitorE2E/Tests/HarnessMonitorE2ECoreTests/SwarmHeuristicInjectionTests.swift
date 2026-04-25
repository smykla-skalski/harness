import Foundation
import XCTest
@testable import HarnessMonitorE2ECore

final class SwarmHeuristicInjectionTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("swarm-heuristic-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testAppendResolvesAgentFromSessionStateAgentMap() throws {
        let projectDir = tempDir.appendingPathComponent("project", isDirectory: true)
        let dataHome = tempDir.appendingPathComponent("data-home", isDirectory: true)
        let harnessBinary = tempDir.appendingPathComponent("fake-harness.sh")

        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dataHome, withIntermediateDirectories: true)
        try makeFakeHarness(at: harnessBinary)

        let output = try SwarmHeuristicInjection.append(.init(
            code: "python_traceback_output",
            agentID: "claude-123",
            sessionID: "sess-test",
            projectDir: projectDir,
            dataHome: dataHome,
            harnessBinary: harnessBinary
        ))

        XCTAssertTrue(output.logPath.hasSuffix("/agents/sessions/claude/runtime-session-1/raw.jsonl"))
        let logURL = URL(fileURLWithPath: output.logPath)
        let payload = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(payload.contains("Traceback"), "payload=\(payload)")
    }

    private func makeFakeHarness(at url: URL) throws {
        let script = #"""
        #!/bin/bash
        set -euo pipefail

        if [[ "${1:-}" == "session" && "${2:-}" == "status" ]]; then
          printf '%s\n' '{"agents":{"claude-123":{"name":"Swarm Observer","runtime":"claude","agent_session_id":"runtime-session-1"}}}'
          exit 0
        fi

        printf '%s\n' '{}'
        exit 0
        """#

        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
