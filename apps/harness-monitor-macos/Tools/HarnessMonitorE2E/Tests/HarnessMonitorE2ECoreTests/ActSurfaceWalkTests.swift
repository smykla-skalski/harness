import Foundation
import XCTest

@testable import HarnessMonitorE2ECore

/// Coverage for `RecordingTriage.walkRecordingActs(markerDir:uiSnapshotsDir:taskReviewID:)`.
/// Builds a synthetic run dir on disk, drops the canonical marker payload + a
/// matching `swarm-actN.txt` hierarchy fragment, and asserts that the helper
/// composes parseActMarker + parseAccessibilityIdentifiers + assertActSurface
/// + assertWholeRunInvariants into one ordered ActSurfaceReport.
final class ActSurfaceWalkTests: XCTestCase {
  func testWalkProducesPerActAndWholeRunFindings() throws {
    let work = makeTempDir()
    defer { try? FileManager.default.removeItem(at: work) }
    let markers = work.appendingPathComponent("markers", isDirectory: true)
    let snapshots = work.appendingPathComponent("snapshots", isDirectory: true)
    try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)

    try writeMarker(
      markers.appendingPathComponent("act1.ready"),
      body: """
        act=act1
        session_id=sess-foo
        leader_id=claude-1
        """)
    try writeSnapshot(
      snapshots.appendingPathComponent("swarm-act1.txt"),
      body: """
        Other, 0x1, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'harness.toolbar.chrome.state', label: 'windowTitle=Cockpit'
        Cell, 0x2, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'harness.sidebar.session.sess-foo', Selected
        Other, 0x3, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'harness.toolbar.connection-badge', label: 'Connection: WS, latency 0 milliseconds'
        """)

    try writeMarker(
      markers.appendingPathComponent("act3.ready"),
      body: """
        act=act3
        task_review_id=task-1
        task_autospawn_id=task-2
        task_arbitration_id=task-3
        task_refusal_id=task-4
        task_signal_id=task-5
        """)
    try writeSnapshot(
      snapshots.appendingPathComponent("swarm-act3.txt"),
      body: """
        Other, 0x4, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'harness.session.tasks.state', label: 'taskCount=5, taskIDs=task-1,task-2,task-3,task-4,task-5'
        Other, 0x5, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'harness.toolbar.connection-badge', label: 'Connection: WS, latency 0 milliseconds'
        """)

    let report = try RecordingTriage.walkRecordingActs(
      markerDir: markers,
      uiSnapshotsDir: snapshots,
      taskReviewID: nil
    )
    XCTAssertEqual(report.perAct.map { $0.act }, ["act1", "act3"])
    let act1 = report.perAct[0]
    XCTAssertGreaterThan(act1.identifierCount, 0)
    XCTAssertEqual(act1.payload["session_id"], "sess-foo")
    XCTAssertTrue(act1.findings.contains { $0.id == "swarm.act1.cockpit" && $0.verdict == .found })
    XCTAssertTrue(
      report.wholeRun.contains { $0.id == "swarm.invariant.daemonHealth" && $0.verdict == .found })
  }

  func testWalkAutoDerivesTaskReviewIDFromAct3Marker() throws {
    let work = makeTempDir()
    defer { try? FileManager.default.removeItem(at: work) }
    let markers = work.appendingPathComponent("m", isDirectory: true)
    let snapshots = work.appendingPathComponent("s", isDirectory: true)
    try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
    try writeMarker(
      markers.appendingPathComponent("act3.ready"),
      body: """
        act=act3
        task_review_id=task-1
        """)
    try writeSnapshot(
      snapshots.appendingPathComponent("swarm-act3.txt"),
      body: """
        Other, 0x1, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'harness.review.task.awaiting.task-1'
        Other, 0x2, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'harness.review.task.reviewer-claim.task-1.claude'
        """)

    let report = try RecordingTriage.walkRecordingActs(
      markerDir: markers,
      uiSnapshotsDir: snapshots,
      taskReviewID: nil
    )
    XCTAssertTrue(
      report.wholeRun.contains {
        $0.id == "swarm.invariant.taskReviewProgression" && $0.verdict == .found
      })
  }

  func testWalkSkipsActsWithoutMatchingSnapshot() throws {
    let work = makeTempDir()
    defer { try? FileManager.default.removeItem(at: work) }
    let markers = work.appendingPathComponent("m", isDirectory: true)
    let snapshots = work.appendingPathComponent("s", isDirectory: true)
    try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
    try writeMarker(markers.appendingPathComponent("act1.ready"), body: "act=act1\n")
    let report = try RecordingTriage.walkRecordingActs(
      markerDir: markers,
      uiSnapshotsDir: snapshots,
      taskReviewID: nil
    )
    XCTAssertEqual(report.perAct.count, 1)
    XCTAssertEqual(report.perAct[0].identifierCount, 0)
  }

  private func writeMarker(_ url: URL, body: String) throws {
    try body.write(to: url, atomically: true, encoding: .utf8)
  }

  private func writeSnapshot(_ url: URL, body: String) throws {
    try body.write(to: url, atomically: true, encoding: .utf8)
  }

  private func makeTempDir() -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("act-walk-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}
