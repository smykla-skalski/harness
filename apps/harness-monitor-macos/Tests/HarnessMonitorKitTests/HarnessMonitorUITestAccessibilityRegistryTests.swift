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
      HarnessMonitorAccessibility.sessionCockpitScrollView
        == "harness.session.cockpit.scroll"
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

  @Test("MCP reliability identifiers match UI-test mirror")
  func mcpReliabilityIdentifiersMirror() throws {
    #expect(HarnessMonitorAccessibility.preferencesMCPSection == "harness.preferences.mcp")
    #expect(
      HarnessMonitorAccessibility.preferencesMCPRegistryHostToggle
        == "harness.preferences.mcp.registry-host"
    )
    #expect(HarnessMonitorAccessibility.preferencesMCPStatus == "harness.preferences.mcp.status")
    #expect(HarnessMonitorAccessibility.mcpToolbarStatus == "harness.toolbar.mcp.status")
    #expect(HarnessMonitorAccessibility.mcpBanner == "harness.content.mcp.banner")

    let contentToolbar = try sourceFile(named: "ContentToolbarItems.swift")
    let contentChrome = try sourceFile(named: "ContentChromeSupport.swift")
    let preferencesMCP = try sourceFile(named: "PreferencesMCPSection.swift")

    #expect(contentToolbar.contains("mcpToolbarStatus"))
    #expect(contentChrome.contains("MCPStatusBanner(status: mcpStatus)"))
    #expect(preferencesMCP.contains("preferencesMCPStatus"))
  }

  @Test("New session capability identifiers match UI-test mirror")
  func newSessionCapabilityIdentifiersMirror() {
    #expect(
      HarnessMonitorAccessibility.newSessionCapabilityRow("Copilot CLI")
        == "harness.new-session.capability.copilot-cli"
    )
    #expect(
      HarnessMonitorAccessibility.newSessionCapabilityProbe("Copilot CLI")
        == "harness.new-session.capability.copilot-cli.probe"
    )
    #expect(
      HarnessMonitorAccessibility.newSessionCapabilityTransportButton(
        "Copilot CLI",
        transportID: "managed:copilot"
      )
        == "harness.new-session.capability.copilot-cli.transport.managed-copilot"
    )
  }

  @Test("Agents runtime identifiers match UI-test mirror")
  func agentsRuntimeIdentifiersMirror() {
    #expect(
      HarnessMonitorAccessibility.agentRuntimeStrip("worker-codex")
        == "harness.agents.detail.runtime.strip.worker-codex"
    )
    #expect(
      HarnessMonitorAccessibility.agentRuntimeWatchdog("worker-codex")
        == "harness.agents.detail.runtime.watchdog.worker-codex"
    )
    #expect(
      HarnessMonitorAccessibility.agentRuntimePendingPermissions("worker-codex")
        == "harness.agents.detail.runtime.pending-permissions.worker-codex"
    )
    #expect(
      HarnessMonitorAccessibility.agentRuntimeDeadline("worker-codex")
        == "harness.agents.detail.runtime.deadline.worker-codex"
    )
    #expect(
      HarnessMonitorAccessibility.agentRuntimeDisclosure("worker-codex")
        == "harness.agents.detail.runtime.disclosure.worker-codex"
    )
    #expect(
      HarnessMonitorAccessibility.agentRuntimeDisclosureContent("worker-codex")
        == "harness.agents.detail.runtime.disclosure-content.worker-codex"
    )
    #expect(
      HarnessMonitorAccessibility.agentRuntimeWatchdogAccessibilityState
        == "harness.agents.detail.runtime.watchdog.accessibility.state"
    )
    #expect(
      HarnessMonitorAccessibility.toolCallTimelineAccessibilityState
        == "harness.window.agents.tool-call-timeline.accessibility.state"
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
    let agentLaneView = try sourceFile(named: "SessionAgentLaneViews.swift")
    let taskActionsSheet = try sourceFile(named: "Actions/TaskActionsSheet.swift")
    let toastView = try sourceFile(named: "HarnessMonitorFeedbackToastView.swift")

    #expect(cockpitView.contains("SessionCockpitHeuristicIssuesSection"))
    #expect(cockpitView.contains("sessionCockpitScrollView"))
    #expect(taskLaneView.contains("sessionTaskListState"))
    #expect(taskActionsSheet.contains("ReviewStatePanel(task: task)"))
    #expect(taskLaneView.contains("harnessTrackMCPElement"))
    #expect(agentLaneView.contains("harnessTrackMCPElement"))
    #expect(toastView.contains("feedback.accessibilityIdentifier"))
  }

  @Test("Task actions sheet keeps using presented session detail during refresh")
  func taskActionsSheetUsesPresentedSessionDetailDuringRefresh() throws {
    let taskActionsSheet = try sourceFile(named: "Actions/TaskActionsSheet.swift")

    #expect(taskActionsSheet.contains("contentUI.sessionDetail.presentedSessionDetail"))
  }

  @MainActor
  @Test("Harness MCP tracked elements register in the shared runtime registry")
  func harnessTrackedElementsRegisterInRuntimeRegistry() async {
    let registry = HarnessMonitorMCPAccessibilityService.shared.registry
    let identifier = "harness.test.runtime-registration"

    await registry.unregisterElement(identifier: identifier)

    let host = NSHostingView(
      rootView: Text("Pointer Target")
        .harnessTrackMCPElement(identifier, kind: .row, label: "Pointer Target")
    )
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 320, height: 120),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )

    defer {
      window.orderOut(nil)
      window.contentView = nil
    }

    host.frame = CGRect(x: 0, y: 0, width: 320, height: 120)
    window.contentView = host
    window.layoutIfNeeded()
    host.layoutSubtreeIfNeeded()

    #expect(
      await waitUntil {
        await registry.element(identifier: identifier) != nil
      }
    )

    let element = await registry.element(identifier: identifier)
    #expect(element?.label == "Pointer Target")
    #expect((element?.frame.width ?? 0) > 0)
    #expect((element?.frame.height ?? 0) > 0)

    window.contentView = nil
    host.removeFromSuperview()

    #expect(
      await waitUntil {
        await registry.element(identifier: identifier) == nil
      }
    )
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

  private func waitUntil(
    timeout: Duration = .seconds(1),
    interval: Duration = .milliseconds(10),
    _ predicate: @escaping @Sendable () async -> Bool
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
      if await predicate() {
        return true
      }
      await Task.yield()
      try? await Task.sleep(for: interval)
    }
    return await predicate()
  }
}
