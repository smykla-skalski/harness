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
    XCTAssertEqual(
      layout.dataRoot.path,
      "/Users/test/Library/Group Containers/Q498EB36N4.io.harnessmonitor/HarnessMonitorSwarmE2E/run-123/data-root"
    )
    XCTAssertEqual(
      layout.dataHome.path,
      "/Users/test/Library/Group Containers/Q498EB36N4.io.harnessmonitor/HarnessMonitorSwarmE2E/run-123/data-root/data-home"
    )
    XCTAssertEqual(
      layout.syncRoot.path,
      "/Users/test/Library/Containers/io.harnessmonitor.agents-e2e-tests.xctrunner/Data/tmp/HarnessMonitorSwarmE2E/run-123"
    )
    XCTAssertEqual(layout.syncDir.path, layout.syncRoot.appendingPathComponent("e2e-sync").path)
    XCTAssertEqual(layout.derivedDataPath.path, "/common/xcode-derived-e2e")
    XCTAssertEqual(layout.uiSnapshotsSource.lastPathComponent, "ui-snapshots")
    XCTAssertEqual(layout.screenRecordingControlDirectory.lastPathComponent, "recording-control")
  }

  func testAppGroupOverrideAdjustsDefaultDataHomePath() {
    let layout = SwarmRunLayout(
      runID: "run-123",
      repoRoot: URL(fileURLWithPath: "/repo", isDirectory: true),
      commonRepoRoot: URL(fileURLWithPath: "/common", isDirectory: true),
      temporaryDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
      homeDirectory: URL(fileURLWithPath: "/Users/test", isDirectory: true),
      appGroupIdentifierOverride: "TEAM123.io.harnessmonitor"
    )

    XCTAssertEqual(
      layout.dataHome.path,
      "/Users/test/Library/Group Containers/TEAM123.io.harnessmonitor/HarnessMonitorSwarmE2E/run-123/data-root/data-home"
    )
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

  func testEnsureGeneratedDataRootsNonIndexableMarksEveryGeneratedRoot() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("swarm-layout-noindex-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let dataRoot = root.appendingPathComponent("data-root", isDirectory: true)
    let dataHome = root.appendingPathComponent("custom-data-home", isDirectory: true)
    let layout = SwarmRunLayout(
      runID: "run-123",
      repoRoot: URL(fileURLWithPath: "/repo", isDirectory: true),
      commonRepoRoot: URL(fileURLWithPath: "/common", isDirectory: true),
      temporaryDirectory: root.appendingPathComponent("tmp", isDirectory: true),
      homeDirectory: URL(fileURLWithPath: "/Users/test", isDirectory: true),
      dataRootOverride: dataRoot,
      dataHomeOverride: dataHome
    )

    try layout.ensureGeneratedDataRootsNonIndexable()
    try layout.ensureGeneratedDataRootsNonIndexable()

    for directory in [
      layout.dataRoot,
      layout.dataHome,
      layout.dataHome.appendingPathComponent("harness", isDirectory: true),
    ] {
      let marker = directory.appendingPathComponent(SwarmRunLayout.nonIndexableMarkerName)
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: marker.path),
        "Missing no-index marker at \(marker.path)"
      )
    }
  }
}
