import Foundation
import XCTest
@testable import HarnessMonitorE2ECore

final class SwarmActDriverTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("swarm-act-driver-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testRunActDriverWritesAct1ReadyFromSessionStateAgentMap() throws {
        let repoRoot = tempDir.appendingPathComponent("repo", isDirectory: true)
        let projectDir = tempDir.appendingPathComponent("project", isDirectory: true)
        let stateRoot = tempDir.appendingPathComponent("state-root", isDirectory: true)
        let dataHome = tempDir.appendingPathComponent("data-home", isDirectory: true)
        let syncDir = tempDir.appendingPathComponent("sync", isDirectory: true)
        let probeJSON = tempDir.appendingPathComponent("probe.json")
        let harnessBinary = tempDir.appendingPathComponent("fake-harness.sh")

        for directory in [repoRoot, projectDir, stateRoot, dataHome, syncDir] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data(#"{"required_missing":[],"runtimes":{}}"#.utf8).write(to: probeJSON)
        try makeFakeHarness(at: harnessBinary)

        let inputs = SwarmActDriverInputs(
            repoRoot: repoRoot,
            stateRoot: stateRoot,
            dataHome: dataHome,
            projectDir: projectDir,
            syncDir: syncDir,
            sessionID: "sess-test",
            harnessBinary: harnessBinary,
            probeJSON: probeJSON
        )

        let actReadyURL = syncDir.appendingPathComponent("act1.ready")
        let actAckURL = syncDir.appendingPathComponent("act1.ack")
        let runnerFinished = expectation(description: "act driver returned")
        let runnerFailed = expectation(description: "act driver failed")

        DispatchQueue.global().async {
            defer { runnerFinished.fulfill() }
            do {
                try SwarmFullFlowOrchestrator.runActDriver(inputs)
                XCTFail("expected fake harness to stop the run after act1")
            } catch {
                runnerFailed.fulfill()
            }
        }

        XCTAssertTrue(
            waitForFile(at: actReadyURL, timeout: 5),
            "expected act1.ready after leader join resolved from a session-state agent map"
        )

        let marker = try String(contentsOf: actReadyURL, encoding: .utf8)
        XCTAssertTrue(marker.contains("leader_id=agent-leader"), "marker=\(marker)")
        XCTAssertTrue(marker.contains("session_id=sess-test"), "marker=\(marker)")

        try "ack\n".write(to: actAckURL, atomically: true, encoding: .utf8)
        wait(for: [runnerFailed, runnerFinished], timeout: 10)
    }

    private func waitForFile(at url: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func makeFakeHarness(at url: URL) throws {
        let script = #"""
        #!/bin/bash
        set -euo pipefail

        if [[ "${1:-}" == "session" && "${2:-}" == "start" ]]; then
          printf '%s\n' '{"session_id":"sess-test"}'
          exit 0
        fi

        if [[ "${1:-}" == "session" && "${2:-}" == "join" ]]; then
          name=""
          previous=""
          for arg in "$@"; do
            if [[ "$previous" == "--name" ]]; then
              name="$arg"
              break
            fi
            previous="$arg"
          done

          if [[ "$name" == "Swarm Leader" ]]; then
            printf '%s\n' '{"agents":{"agent-leader":{"name":"Swarm Leader","runtime":"claude","role":"leader"}}}'
            exit 0
          fi

          printf '%s\n' 'forced stop after act1' >&2
          exit 9
        fi

        printf '%s\n' '{}'
        exit 0
        """#

        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
