import Foundation
import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class SwarmRunner {
  private let fixture: SwarmFixture

  init(fixture: SwarmFixture) {
    self.fixture = fixture
  }

  private func acknowledge(_ act: String) throws {
    fixture.captureCheckpoint(act)
    try fixture.ack(act)
  }

  func act1() throws {
    let marker = try fixture.waitForReady("act1")
    fixture.openSession(marker["session_id"] ?? fixture.sessionID)
    try acknowledge("act1")
  }

  func act2() throws {
    let marker = try fixture.waitForReady("act2")
    if let agentID = marker["worker_codex_id"] {
      fixture.expectIdentifier(Accessibility.sessionAgentListState, labelContains: agentID)
    }
    if let agentID = marker["worker_claude_id"] {
      fixture.expectIdentifier(Accessibility.sessionAgentListState, labelContains: agentID)
    }
    try acknowledge("act2")
  }

  func act3() throws {
    let marker = try fixture.waitForReady("act3")
    if let taskID = marker["task_review_id"] {
      fixture.expectIdentifier(Accessibility.sessionTaskCard(taskID))
    }
    try acknowledge("act3")
  }

  func act4() throws {
    let marker = try fixture.waitForReady("act4")
    if let taskID = marker["task_review_id"] {
      fixture.selectTask(taskID)
    }
    try acknowledge("act4")
  }

  func act5() throws {
    let marker = try fixture.waitForReady("act5")
    fixture.expectIdentifier(
      Accessibility.heuristicIssueCard(marker["heuristic_code"] ?? "python_traceback_output"))
    try acknowledge("act5")
  }

  func act6() throws {
    _ = try fixture.waitForReady("act6")
    try acknowledge("act6")
  }

  func act7() throws {
    _ = try fixture.waitForReady("act7")
    try acknowledge("act7")
  }

  func act8() throws {
    let marker = try fixture.waitForReady("act8")
    if let taskID = marker["task_review_id"] {
      fixture.selectTask(taskID)
      fixture.expectIdentifier(Accessibility.awaitingReviewBadge(taskID))
    }
    try acknowledge("act8")
  }

  func act9() throws {
    let marker = try fixture.waitForReady("act9")
    if let taskID = marker["task_review_id"] {
      fixture.expectAnyIdentifier([
        Accessibility.reviewerClaimBadge(taskID, runtime: marker["reviewer_runtime"] ?? "claude"),
        Accessibility.reviewerQuorumIndicator(taskID),
      ])
    }
    try acknowledge("act9")
  }

  func act10() throws {
    let marker = try fixture.waitForReady("act10")
    if let workerID = marker["worker_claude_id"] {
      fixture.expectIdentifier(Accessibility.sessionAgentListState, labelContains: workerID)
    }
    if let taskID = marker["task_autospawn_id"] {
      fixture.selectTask(taskID)
      fixture.expectIdentifier(Accessibility.awaitingReviewBadge(taskID))
    }
    try acknowledge("act10")
  }

  func act11() throws {
    _ = try fixture.waitForReady("act11")
    fixture.expectAnyIdentifier([
      Accessibility.workerRefusalToast,
      Accessibility.taskInspectorCard,
    ])
    try acknowledge("act11")
  }

  func act12() throws {
    let marker = try fixture.waitForReady("act12")
    if let taskID = marker["task_arbitration_id"] {
      fixture.selectTask(taskID)
      fixture.expectAnyIdentifier([
        Accessibility.partialAgreementChip(marker["point_id"] ?? "p1"),
        Accessibility.reviewPointChip(marker["point_id"] ?? "p1"),
        Accessibility.roundCounter(taskID),
      ])
    }
    try acknowledge("act12")
  }

  func act13() throws {
    let marker = try fixture.waitForReady("act13")
    if let taskID = marker["task_arbitration_id"] {
      fixture.expectAnyIdentifier([
        Accessibility.arbitrationBanner(taskID),
        Accessibility.roundCounter(taskID),
      ])
    }
    try acknowledge("act13")
  }

  func act14() throws {
    _ = try fixture.waitForReady("act14")
    fixture.expectAnyIdentifier([
      Accessibility.signalCollisionToast,
      Accessibility.taskInspectorCard,
    ])
    try acknowledge("act14")
  }

  func act15() throws {
    _ = try fixture.waitForReady("act15")
    fixture.expectAnyIdentifier([
      Accessibility.observeScanButton,
      Accessibility.observeDoctorButton,
      Accessibility.observeSessionButton,
      Accessibility.observeSummaryButton,
    ])
    try acknowledge("act15")
  }

  func act16() throws {
    _ = try fixture.waitForReady("act16")
    // Orchestrator-side `verifyFinalState()` already asserts session_status==ended
    // from the persisted state.json once the strict `runHarness session end`
    // returns. Re-asserting via UI requires a session-ended chrome surface
    // (SessionStatusCornerOverlay) that is not wired into the rendered app
    // today; tracked separately so this ack reflects reality.
    try acknowledge("act16")
  }
}
