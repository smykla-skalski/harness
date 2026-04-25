import XCTest
@testable import HarnessMonitorE2ECore

final class SwarmRunLayoutTests: XCTestCase {
    func testDefaultLayoutMatchesSwarmE2EContract() {
        let layout = SwarmRunLayout(
            runID: "run-123",
            repoRoot: URL(fileURLWithPath: "/repo", isDirectory: true),
            commonRepoRoot: URL(fileURLWithPath: "/common", isDirectory: true),
            temporaryDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
            homeDirectory: URL(fileURLWithPath: "/Users/test", isDirectory: true)
        )

        XCTAssertEqual(layout.sessionID, "sess-e2e-swarm-run-123")
        XCTAssertEqual(layout.stateRoot.path, "/tmp/HarnessMonitorSwarmE2E/run-123")
        XCTAssertEqual(layout.dataHome.path, "/tmp/HarnessMonitorSwarmE2E/run-123/data-root/data-home")
        XCTAssertEqual(
            layout.syncRoot.path,
            "/Users/test/Library/Containers/io.harnessmonitor.agents-e2e-tests.xctrunner/Data/tmp/HarnessMonitorSwarmE2E/run-123"
        )
        XCTAssertEqual(layout.syncDir.path, layout.syncRoot.appendingPathComponent("e2e-sync").path)
        XCTAssertEqual(layout.derivedDataPath.path, "/common/xcode-derived")
        XCTAssertEqual(layout.uiSnapshotsSource.lastPathComponent, "ui-snapshots")
        XCTAssertEqual(layout.screenRecordingControlDirectory.lastPathComponent, "recording-control")
    }

    func testProjectContextRootUsesStableDigestDirectory() {
        let dataHome = URL(fileURLWithPath: "/tmp/data-home", isDirectory: true)
        let contextRoot = SwarmRunLayout.projectContextRoot(
            projectDir: URL(fileURLWithPath: "/tmp/project-under-test", isDirectory: true),
            dataHome: dataHome
        )

        XCTAssertTrue(contextRoot.path.hasPrefix("/tmp/data-home/harness/projects/project-"))
        XCTAssertTrue(contextRoot.path.hasSuffix("/harness/projects/project-a2c9c0a0a46868bf"))
    }
}
