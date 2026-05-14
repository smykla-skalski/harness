import AppKit
import Foundation
import SwiftUI
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
      HarnessMonitorAccessibility.sessionTaskSelection("task-1")
        == "harness.session.task.selection.task-1"
    )
  }

  @Test("Action console identifiers match UI-test mirror")
  func actionConsoleIdentifiersMirror() {
    #expect(
      HarnessMonitorAccessibility.createTaskTitleField
        == "harness.action.create-task.title-field"
    )
    #expect(HarnessMonitorAccessibility.createTaskButton == "harness.action.create-task.submit")
    #expect(
      HarnessMonitorAccessibility.sessionAgentCreateOpenButton
        == "harness.session.agents.create-agent.open"
    )
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
      HarnessMonitorAccessibility.submitTaskForReviewButton
        == "harness.action.task.submit-for-review"
    )
    #expect(
      HarnessMonitorAccessibility.claimTaskReviewButton
        == "harness.action.task.claim-review"
    )
    #expect(
      HarnessMonitorAccessibility.submitTaskReviewButton
        == "harness.action.task.submit-review"
    )
    #expect(
      HarnessMonitorAccessibility.respondTaskReviewButton
        == "harness.action.task.respond-review"
    )
    #expect(HarnessMonitorAccessibility.arbitrateTaskButton == "harness.action.task.arbitrate")
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
      HarnessMonitorAccessibility.sessionCockpitScrollView
        == "harness.session.cockpit.scroll"
    )
    #expect(
      HarnessMonitorAccessibility.sessionAgentListState
        == "harness.session.agents.state"
    )
    #expect(
      HarnessMonitorAccessibility.sessionAgentListHeader
        == "harness.session.agents.header"
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

  @Test("Timeline navigation identifiers match UI-test mirror")
  func timelineNavigationIdentifiersMirror() {
    #expect(
      HarnessMonitorAccessibility.sessionTimelineNavigation
        == "harness.session.timeline.navigation"
    )
    #expect(
      HarnessMonitorAccessibility.sessionTimelineNavigationStatus
        == "harness.session.timeline.navigation.status"
    )
    #expect(
      HarnessMonitorAccessibility.sessionTimelineVisibleStatus
        == "harness.session.timeline.navigation.visible-status"
    )
    #expect(
      HarnessMonitorAccessibility.sessionTimelineOlderButton
        == "harness.session.timeline.navigation.older"
    )
    #expect(
      HarnessMonitorAccessibility.sessionTimelineLatestButton
        == "harness.session.timeline.navigation.latest"
    )
    #expect(
      HarnessMonitorAccessibility.sessionTimelineNewerButton
        == "harness.session.timeline.navigation.newer"
    )
  }

  @Test("ACP bridge banner identifiers match UI-test mirror")
  func acpBridgeBannerIdentifiersMirror() throws {
    #expect(
      HarnessMonitorAccessibility.contentAcpBridgeBanner
        == "harness.content.acp-bridge.banner"
    )
    #expect(
      HarnessMonitorAccessibility.contentAcpBridgeOpenLogButton
        == "harness.content.acp-bridge.open-log"
    )
    #expect(
      HarnessMonitorAccessibility.contentAcpBridgeRunDoctorButton
        == "harness.content.acp-bridge.run-doctor"
    )

    let contentBridges = try sourceFile(named: "ContentView+Bridges.swift")
    #expect(contentBridges.contains("contentAcpBridgeBanner"))
    #expect(contentBridges.contains("contentAcpBridgeOpenLogButton"))
    #expect(contentBridges.contains("contentAcpBridgeRunDoctorButton"))
    let contentChrome = try sourceFile(named: "ContentChromeSupport.swift")
    let contentView = try sourceFile(named: "ContentView.swift")
    #expect(contentChrome.contains("ContentAcpBridgeBannerBridge("))
    #expect(!contentView.contains("ContentAcpBridgeBannerBridge("))
  }

}
