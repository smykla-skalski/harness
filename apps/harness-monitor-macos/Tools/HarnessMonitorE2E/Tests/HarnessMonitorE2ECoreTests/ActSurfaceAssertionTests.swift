import Foundation
import XCTest

@testable import HarnessMonitorE2ECore

/// Coverage for `RecordingTriage.assertActSurface(act:payload:identifiers:)`.
/// Each test pins one row from `references/act-marker-matrix.md`. Real
/// hierarchy fragments are inlined so the assertions stay deterministic when
/// fixtures rotate.
final class ActSurfaceAssertionTests: XCTestCase {
  // MARK: - Helpers

  private func parse(_ text: String) -> [RecordingTriage.AccessibilityIdentifier] {
    RecordingTriage.parseAccessibilityIdentifiers(from: text)
  }

  private func verdict(_ findings: [RecordingTriage.ChecklistFinding], for id: String)
    -> RecordingTriage.ChecklistFinding.Verdict?
  {
    findings.first { $0.id == id }?.verdict
  }

  // MARK: - Acts

  func testAct1FindsCockpitAndSelectedSidebarRow() {
    let session = "sess-foo"
    let text = """
      Other, 0x1, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'harness.toolbar.chrome.state', label: 'toolbarTitle=native-window, windowTitle=Cockpit, toolbarBackground=automatic'
      Cell, 0x2, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'harness.sidebar.session.\(session)', label: 'foo', Selected
      """
    let findings = RecordingTriage.assertActSurface(
      act: "act1",
      payload: ["session_id": session, "leader_id": "claude-1"],
      identifiers: parse(text)
    )
    XCTAssertEqual(verdict(findings, for: "swarm.act1.cockpit"), .found)
    XCTAssertEqual(verdict(findings, for: "swarm.act1.sidebarRow"), .found)
  }

  func testAct1FlagsMissingCockpitWindow() {
    let session = "sess-foo"
    let text = """
      Cell, 0x2, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'harness.sidebar.session.\(session)', Selected
      """
    let findings = RecordingTriage.assertActSurface(
      act: "act1",
      payload: ["session_id": session, "leader_id": "claude-1"],
      identifiers: parse(text)
    )
    XCTAssertEqual(verdict(findings, for: "swarm.act1.cockpit"), .notFound)
    XCTAssertEqual(verdict(findings, for: "swarm.act1.sidebarRow"), .found)
  }

  func testAct1FlagsUnselectedSidebarRow() {
    let session = "sess-foo"
    let text = """
      Other, 0x1, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'harness.toolbar.chrome.state', label: 'windowTitle=Cockpit'
      Cell, 0x2, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'harness.sidebar.session.\(session)', label: 'no selection here'
      """
    let findings = RecordingTriage.assertActSurface(
      act: "act1",
      payload: ["session_id": session, "leader_id": "claude-1"],
      identifiers: parse(text)
    )
    XCTAssertEqual(verdict(findings, for: "swarm.act1.sidebarRow"), .notFound)
  }

  func testAct2FindsRolesWhenAllIDsPresent() {
    let payload: [String: String] = [
      "worker_codex_id": "codex-1",
      "worker_claude_id": "claude-2",
      "reviewer_claude_id": "claude-3",
      "reviewer_codex_id": "codex-4",
      "observer_id": "claude-5",
      "improver_id": "codex-6",
    ]
    let allIDs = payload.values.sorted().joined(separator: ",")
    let text = """
      Other, 0x1, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'harness.session.agents.state', label: 'agentCount=6, agentIDs=\(allIDs), runtimes=claude,codex'
      """
    let findings = RecordingTriage.assertActSurface(
      act: "act2",
      payload: payload,
      identifiers: parse(text)
    )
    XCTAssertEqual(verdict(findings, for: "swarm.act2.roles"), .found)
  }

  func testAct2FlagsMissingRoleID() {
    let payload: [String: String] = [
      "worker_codex_id": "codex-1",
      "worker_claude_id": "claude-2",
      "observer_id": "claude-5",
      "improver_id": "codex-6",
    ]
    let text = """
      Other, 0x1, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'harness.session.agents.state', label: 'agentCount=2, agentIDs=codex-1,claude-2, runtimes=claude,codex'
      """
    let findings = RecordingTriage.assertActSurface(
      act: "act2",
      payload: payload,
      identifiers: parse(text)
    )
    XCTAssertEqual(verdict(findings, for: "swarm.act2.roles"), .notFound)
  }

  func testAct3FindsAllFiveTaskIDs() {
    let payload: [String: String] = [
      "task_review_id": "task-1",
      "task_autospawn_id": "task-2",
      "task_arbitration_id": "task-3",
      "task_refusal_id": "task-4",
      "task_signal_id": "task-5",
    ]
    let text = """
      Other, 0x1, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'harness.session.tasks.state', label: 'taskCount=5, taskIDs=task-1,task-3,task-2,task-5,task-4'
      """
    let findings = RecordingTriage.assertActSurface(
      act: "act3",
      payload: payload,
      identifiers: parse(text)
    )
    XCTAssertEqual(verdict(findings, for: "swarm.act3.tasks"), .found)
  }

  func testAct3FlagsMissingTaskID() {
    let payload: [String: String] = [
      "task_review_id": "task-1",
      "task_signal_id": "task-5",
    ]
    let text = """
      Other, 0x1, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'harness.session.tasks.state', label: 'taskCount=1, taskIDs=task-1'
      """
    let findings = RecordingTriage.assertActSurface(
      act: "act3",
      payload: payload,
      identifiers: parse(text)
    )
    XCTAssertEqual(verdict(findings, for: "swarm.act3.tasks"), .notFound)
  }

  func testAct4FindsReviewAndAutospawn() {
    let payload: [String: String] = [
      "task_review_id": "task-1",
      "task_autospawn_id": "task-2",
    ]
    let text = """
      Other, 0x1, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'harness.session.tasks.state', label: 'taskCount=2, taskIDs=task-1,task-2'
      """
    let findings = RecordingTriage.assertActSurface(
      act: "act4",
      payload: payload,
      identifiers: parse(text)
    )
    XCTAssertEqual(verdict(findings, for: "swarm.act4.tasks"), .found)
  }

  func testAct5FindsHeuristicCard() {
    let text = """
      Other, 0x1, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'heuristicIssueCard.python_traceback_output', label: 'python traceback'
      """
    let findings = RecordingTriage.assertActSurface(
      act: "act5",
      payload: ["observer_id": "claude-5", "heuristic_code": "python_traceback_output"],
      identifiers: parse(text)
    )
    XCTAssertEqual(verdict(findings, for: "swarm.act5.heuristic"), .found)
  }

  func testAct5FlagsMissingHeuristicCard() {
    let findings = RecordingTriage.assertActSurface(
      act: "act5",
      payload: ["observer_id": "claude-5", "heuristic_code": "python_traceback_output"],
      identifiers: []
    )
    XCTAssertEqual(verdict(findings, for: "swarm.act5.heuristic"), .notFound)
  }

  func testAct6FindsImproverAgentCard() {
    // Real UI doesn't emit `harness.session.agent.<id>` per agent. The
    // improver appears as a substring of the `harness.session.agents.state`
    // label payload (`agentIDs=...,codex-improver,...`).
    let text = """
      Other, 0x1, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'harness.session.agents.state', label: 'agentCount=11, agentIDs=claude-1,codex-improver,gemini-1'
      """
    let findings = RecordingTriage.assertActSurface(
      act: "act6",
      payload: ["improver_id": "codex-improver"],
      identifiers: parse(text)
    )
    XCTAssertEqual(verdict(findings, for: "swarm.act6.improver"), .found)
  }

  func testAct7FindsVibeWorkerWhenPresent() {
    let text = """
      Other, 0x1, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'harness.session.agents.state', label: 'agentCount=12, agentIDs=claude-1,codex-1,vibe-worker'
      """
    let findings = RecordingTriage.assertActSurface(
      act: "act7",
      payload: ["vibe_worker_id": "vibe-worker"],
      identifiers: parse(text)
    )
    XCTAssertEqual(verdict(findings, for: "swarm.act7.vibeRoster"), .found)
  }

  func testAct7TreatsEmptyVibeAsNeedsVerification() {
    let findings = RecordingTriage.assertActSurface(
      act: "act7",
      payload: ["vibe_worker_id": ""],
      identifiers: []
    )
    XCTAssertEqual(verdict(findings, for: "swarm.act7.vibeRoster"), .needsVerification)
  }

  func testAct8FindsAwaitingReviewBadge() {
    // Real UI helper `HarnessMonitorAccessibility.awaitingReviewBadge(taskID)`
    // emits `harness.review.task.awaiting.<slug>`. Detector must consume that
    // canonical string.
    let text = """
      Other, 0x1, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'harness.review.task.awaiting.task-1', label: 'Awaiting review, submitted by codex-1'
      """
    let findings = RecordingTriage.assertActSurface(
      act: "act8",
      payload: ["task_review_id": "task-1", "worker_codex_id": "codex-1"],
      identifiers: parse(text)
    )
    XCTAssertEqual(verdict(findings, for: "swarm.act8.awaitingReview"), .found)
  }

  func testAct9FindsReviewerClaimOrQuorum() {
    let text = """
      Other, 0x1, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'harness.review.task.reviewer-claim.task-1.claude'
      """
    let findings = RecordingTriage.assertActSurface(
      act: "act9",
      payload: ["task_review_id": "task-1", "reviewer_runtime": "claude"],
      identifiers: parse(text)
    )
    XCTAssertEqual(verdict(findings, for: "swarm.act9.reviewerClaim"), .found)
  }

  func testAct9AcceptsQuorumIndicatorAlone() {
    let text = """
      Other, 0x1, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'harness.review.task.reviewer-quorum.task-1'
      """
    let findings = RecordingTriage.assertActSurface(
      act: "act9",
      payload: ["task_review_id": "task-1", "reviewer_runtime": "claude"],
      identifiers: parse(text)
    )
    XCTAssertEqual(verdict(findings, for: "swarm.act9.reviewerClaim"), .found)
  }

  func testAct10FindsAwaitingReviewForAutospawn() {
    let text = """
      Other, 0x1, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'harness.review.task.awaiting.task-2'
      """
    let findings = RecordingTriage.assertActSurface(
      act: "act10",
      payload: ["task_autospawn_id": "task-2", "worker_claude_id": "claude-2"],
      identifiers: parse(text)
    )
    XCTAssertEqual(verdict(findings, for: "swarm.act10.awaitingReview"), .found)
  }

  func testAct11FindsRefusalToast() {
    let text = """
      Other, 0x1, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'harness.toast.worker-refusal'
      """
    let findings = RecordingTriage.assertActSurface(
      act: "act11",
      payload: ["task_refusal_id": "task-4", "worker_claude_id": "claude-2"],
      identifiers: parse(text)
    )
    XCTAssertEqual(verdict(findings, for: "swarm.act11.refusal"), .found)
  }

  func testAct11FindsSelectedAgentsTaskDetail() {
    let text = """
      Other, 0x1, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'harness.agents.task.selection.task-4', label: 'task-4'
      """
    let findings = RecordingTriage.assertActSurface(
      act: "act11",
      payload: ["task_refusal_id": "task-4", "worker_claude_id": "claude-2"],
      identifiers: parse(text)
    )
    XCTAssertEqual(verdict(findings, for: "swarm.act11.refusal"), .found)
  }

  func testAct12FindsRoundCounter() {
    let text = """
      Other, 0x1, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'harness.review.task.round-counter.task-3', label: '1'
      """
    let findings = RecordingTriage.assertActSurface(
      act: "act12",
      payload: ["task_arbitration_id": "task-3", "point_id": "p1"],
      identifiers: parse(text)
    )
    XCTAssertEqual(verdict(findings, for: "swarm.act12.roundOne"), .found)
  }

  func testAct13FindsArbitrationBanner() {
    let text = """
      Other, 0x1, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'harness.banner.arbitration.task-3'
      """
    let findings = RecordingTriage.assertActSurface(
      act: "act13",
      payload: ["task_arbitration_id": "task-3"],
      identifiers: parse(text)
    )
    XCTAssertEqual(verdict(findings, for: "swarm.act13.arbitration"), .found)
  }

  func testAct14FindsSignalCollisionToast() {
    let text = """
      Other, 0x1, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'harness.toast.signal-collision'
      """
    let findings = RecordingTriage.assertActSurface(
      act: "act14",
      payload: ["agent_id": "codex-1"],
      identifiers: parse(text)
    )
    XCTAssertEqual(verdict(findings, for: "swarm.act14.signalCollision"), .found)
  }

  func testAct15FindsObserveAction() {
    let text = """
      Button, 0x1, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'observeScanButton'
      """
    let findings = RecordingTriage.assertActSurface(
      act: "act15",
      payload: ["session_id": "sess-foo"],
      identifiers: parse(text)
    )
    XCTAssertEqual(verdict(findings, for: "swarm.act15.observeAction"), .found)
  }

  func testAct16FindsEndedStatusInSidebarRow() {
    let session = "sess-foo"
    let text = """
      Cell, 0x2, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'harness.sidebar.session.\(session)', label: 'Demo, harness, Repository, Ended, 0 active, 0 moving, sess-foo'
      """
    let findings = RecordingTriage.assertActSurface(
      act: "act16",
      payload: ["session_id": session],
      identifiers: parse(text)
    )
    XCTAssertEqual(verdict(findings, for: "swarm.act16.sessionEnded"), .found)
  }

  func testAct16FlagsLingeringActiveStatusInSidebarRow() {
    let session = "sess-foo"
    let text = """
      Cell, 0x2, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'harness.sidebar.session.\(session)', label: 'Demo, harness, Repository, Active, 3 active, 1 moving, sess-foo'
      """
    let findings = RecordingTriage.assertActSurface(
      act: "act16",
      payload: ["session_id": session],
      identifiers: parse(text)
    )
    XCTAssertEqual(verdict(findings, for: "swarm.act16.sessionEnded"), .notFound)
  }

  func testAct16FlagsMissingSidebarRow() {
    let findings = RecordingTriage.assertActSurface(
      act: "act16",
      payload: ["session_id": "sess-foo"],
      identifiers: []
    )
    XCTAssertEqual(verdict(findings, for: "swarm.act16.sessionEnded"), .notFound)
  }

  func testUnknownActReportsNeedsVerification() {
    let findings = RecordingTriage.assertActSurface(
      act: "act99",
      payload: [:],
      identifiers: []
    )
    XCTAssertEqual(findings.first?.verdict, .needsVerification)
  }
}
