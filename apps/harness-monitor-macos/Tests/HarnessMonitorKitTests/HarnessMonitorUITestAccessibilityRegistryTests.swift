import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

/// The production accessibility helpers in `HarnessMonitorUIPreviewable` are
/// the source of truth. The UI-test harness re-declares the same identifiers
/// in `Tests/HarnessMonitorUITestSupport/HarnessMonitorUITestAccessibility.swift`
/// so `HarnessMonitorUITests` can reference them without importing the
/// Preview-only module.
///
/// This registry test captures the expected strings here and fails loudly if
/// the production helper drifts from the UI-test mirror. When updating the UI
/// test mirror, update the expected values in this test in the same commit.
@Suite("Harness Monitor UI-test accessibility registry mirror")
struct HarnessMonitorUITestAccessibilityRegistryTests {
  @Test("Review badge identifiers match UI-test mirror")
  func reviewBadgeIdentifiersMirror() {
    #expect(
      HarnessMonitorAccessibility.awaitingReviewBadge("task-1")
        == "harness.review.task.awaiting.task-1"
    )
    #expect(
      HarnessMonitorAccessibility.reviewerClaimBadge("task-1", runtime: "claude")
        == "harness.review.task.reviewer-claim.task-1.claude"
    )
    #expect(
      HarnessMonitorAccessibility.reviewerQuorumIndicator("task-1")
        == "harness.review.task.reviewer-quorum.task-1"
    )
    #expect(
      HarnessMonitorAccessibility.reviewPointChip("point-a")
        == "harness.review.task.review-point.point-a"
    )
    #expect(
      HarnessMonitorAccessibility.partialAgreementChip("point-a")
        == "partialAgreementChip.point.point-a"
    )
    #expect(
      HarnessMonitorAccessibility.roundCounter("task-1")
        == "harness.review.task.round-counter.task-1"
    )
    #expect(
      HarnessMonitorAccessibility.improverTaskCard("task-1")
        == "harness.review.task.improver.task-1"
    )
    #expect(
      HarnessMonitorAccessibility.agentsTaskSelection("task-1")
        == "harness.agents.task.selection.task-1"
    )
  }

  @Test("Action console identifiers match UI-test mirror")
  func actionConsoleIdentifiersMirror() {
    #expect(
      HarnessMonitorAccessibility.createTaskTitleField
        == "harness.action.create-task.title-field"
    )
    #expect(HarnessMonitorAccessibility.createTaskButton == "harness.action.create-task.submit")
    #expect(HarnessMonitorAccessibility.assignTaskButton == "harness.action.task.assign")
    #expect(
      HarnessMonitorAccessibility.updateTaskQueuePolicyButton
        == "harness.action.task.update-queue-policy"
    )
    #expect(
      HarnessMonitorAccessibility.updateTaskStatusButton
        == "harness.action.task.update-status"
    )
    #expect(HarnessMonitorAccessibility.checkpointTaskButton == "harness.action.task.checkpoint")
    #expect(
      HarnessMonitorAccessibility.leaderTransferSection
        == "harness.action.leader-transfer.section"
    )
    #expect(
      HarnessMonitorAccessibility.leaderTransferPicker
        == "harness.action.leader-transfer.picker"
    )
  }

  @Test("Sidebar, banner, and metric identifiers match UI-test mirror")
  func sidebarAndMetricIdentifiersMirror() {
    #expect(
      HarnessMonitorAccessibility.autoSpawnedBadge("reviewer-1")
        == "harness.sidebar.agent.reviewer-1.auto-spawned"
    )
    #expect(
      HarnessMonitorAccessibility.arbitrationBanner("task-1")
        == "harness.banner.arbitration.task-1"
    )
    #expect(
      HarnessMonitorAccessibility.heuristicIssueCard("OBS_LOG_IO")
        == "heuristicIssueCard.OBS_LOG_IO"
    )
    #expect(
      HarnessMonitorAccessibility.workerRefusalToast
        == "harness.toast.worker-refusal"
    )
    #expect(
      HarnessMonitorAccessibility.signalCollisionToast
        == "harness.toast.signal-collision"
    )
    #expect(
      HarnessMonitorAccessibility.agentRowPersonaChip("worker-1")
        == "harness.session.agent.worker-1.persona"
    )
    #expect(
      HarnessMonitorAccessibility.sessionTaskListState
        == "harness.session.tasks.state"
    )
    #expect(
      HarnessMonitorAccessibility.sessionAgentListState
        == "harness.session.agents.state"
    )
    #expect(HarnessMonitorAccessibility.observeScanButton == "observeScanButton")
    #expect(HarnessMonitorAccessibility.observeDoctorButton == "observeDoctorButton")
    #expect(
      HarnessMonitorAccessibility.metricAwaitingReviewAgent
        == "harness.metrics.awaiting-review-agent"
    )
    #expect(
      HarnessMonitorAccessibility.metricAwaitingReviewTask
        == "harness.metrics.awaiting-review-task"
    )
    #expect(
      HarnessMonitorAccessibility.metricInReviewTask
        == "harness.metrics.in-review-task"
    )
    #expect(
      HarnessMonitorAccessibility.metricArbitrationTask
        == "harness.metrics.arbitration-task"
    )
  }

  @Test("Slug normalises delimiters and casing")
  func slugNormalisation() {
    #expect(
      HarnessMonitorAccessibility.arbitrationBanner("Task_Foo:Bar.1")
        == "harness.banner.arbitration.task-foo-bar1"
    )
    #expect(
      HarnessMonitorAccessibility.heuristicIssueCard("runtime.already_reviewing")
        == "heuristicIssueCard.runtime.already_reviewing"
    )
  }

  @Test("Review accessibility identifiers are attached by production views")
  func reviewAccessibilityIdentifiersAreAttachedByProductionViews() throws {
    let cockpitView = try sourceFile(named: "SessionCockpitView.swift")
    let taskLaneView = try sourceFile(named: "SessionTaskLaneViews.swift")
    let toastView = try sourceFile(named: "HarnessMonitorFeedbackToastView.swift")

    #expect(cockpitView.contains("SessionCockpitHeuristicIssuesSection"))
    #expect(taskLaneView.contains("sessionTaskListState"))
    #expect(toastView.contains("feedback.accessibilityIdentifier"))
  }

  private func sourceFile(named name: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent(
        "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views"
      )
      .appendingPathComponent(name)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
