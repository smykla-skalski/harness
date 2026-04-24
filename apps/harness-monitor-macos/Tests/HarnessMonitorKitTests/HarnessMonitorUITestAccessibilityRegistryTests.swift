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
  @Test("Review inspector identifiers match UI-test mirror")
  func reviewInspectorIdentifiersMirror() {
    #expect(
      HarnessMonitorAccessibility.awaitingReviewBadge("task-1")
        == "harness.inspector.task.awaiting-review-badge.task-1"
    )
    #expect(
      HarnessMonitorAccessibility.reviewerClaimBadge("task-1", runtime: "claude")
        == "harness.inspector.task.reviewer-claim-badge.task-1.claude"
    )
    #expect(
      HarnessMonitorAccessibility.reviewerQuorumIndicator("task-1")
        == "harness.inspector.task.reviewer-quorum.task-1"
    )
    #expect(
      HarnessMonitorAccessibility.reviewPointChip("point-a")
        == "harness.inspector.task.review-point.point-a"
    )
    #expect(
      HarnessMonitorAccessibility.roundCounter("task-1")
        == "harness.inspector.task.round-counter.task-1"
    )
    #expect(
      HarnessMonitorAccessibility.improverTaskCard("task-1")
        == "harness.inspector.task.improver-card.task-1"
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
        == "harness.cockpit.heuristic-issue.obs-log-io"
    )
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
  }
}
