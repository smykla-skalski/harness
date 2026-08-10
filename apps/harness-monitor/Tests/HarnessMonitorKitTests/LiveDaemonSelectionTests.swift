import Foundation
import XCTest

@testable import HarnessMonitorKit

final class LiveDaemonSelectionTests: XCTestCase {
  private func candidate(_ path: String, pid: Int32, startedAt: String) -> LiveDaemonCandidate {
    LiveDaemonCandidate(dataHomeRoot: URL(fileURLWithPath: path), pid: pid, startedAt: startedAt)
  }

  func testPrefersBaseDaemonOverNewerLaneDaemon() {
    let base = candidate("/base", pid: 100, startedAt: "2026-05-26T10:00:00Z")
    let lane = candidate("/lane", pid: 200, startedAt: "2026-05-26T12:00:00Z")
    let chosen = HarnessMonitorPaths.chooseLiveDaemon(base: base, lanes: [lane])
    XCTAssertEqual(
      chosen,
      base,
      "the stable base-container daemon must win over a newer transient lane daemon"
    )
  }

  func testFallsBackToNewestLaneWhenNoBaseDaemon() {
    let older = candidate("/laneA", pid: 1, startedAt: "2026-05-26T10:00:00Z")
    let newer = candidate("/laneB", pid: 2, startedAt: "2026-05-26T12:00:00Z")
    let chosen = HarnessMonitorPaths.chooseLiveDaemon(base: nil, lanes: [older, newer])
    XCTAssertEqual(chosen, newer, "with no base daemon, the newest live lane daemon wins")
  }

  func testReturnsNilWhenNoLiveCandidates() {
    XCTAssertNil(HarnessMonitorPaths.chooseLiveDaemon(base: nil, lanes: []))
  }

  func testEnumeratesBaseLaneAndLegacyManagedManifests() throws {
    let home = FileManager.default.temporaryDirectory
      .appendingPathComponent("live-managed-manifests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let environment = HarnessMonitorEnvironment(
      values: [HarnessMonitorAppGroup.environmentKey: HarnessMonitorAppGroup.identifier],
      homeDirectory: home
    )
    let container =
      home
      .appendingPathComponent("Library/Group Containers", isDirectory: true)
      .appendingPathComponent(HarnessMonitorAppGroup.identifier, isDirectory: true)
    let base = container.appendingPathComponent("harness/daemon/managed/manifest.json")
    let lane =
      container
      .appendingPathComponent("runtime-lanes/lane-a", isDirectory: true)
      .appendingPathComponent("harness/daemon/managed/manifest.json")
    let legacy =
      container
      .appendingPathComponent("runtime-lanes/lane-b", isDirectory: true)
      .appendingPathComponent("harness/daemon/manifest.json")
    for manifest in [base, lane, legacy] {
      try FileManager.default.createDirectory(
        at: manifest.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let ownership = manifest == legacy ? "" : ",\"ownership\":\"managed\""
      try Data("{\"pid\":42\(ownership)}".utf8).write(to: manifest)
    }

    let manifests = HarnessMonitorPaths.liveManagedDaemonManifestURLs(
      using: environment,
      pidIsLive: { $0 == 42 }
    )

    XCTAssertEqual(
      Set(manifests.map(\.standardizedFileURL)),
      Set([base, lane, legacy].map(\.standardizedFileURL))
    )
  }
}
