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
      HarnessMonitorAccessibility.workspaceTaskSelection("task-1")
        == "harness.workspace.task.selection.task-1"
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

  @Test("MCP reliability identifiers match UI-test mirror")
  func mcpReliabilityIdentifiersMirror() throws {
    #expect(HarnessMonitorAccessibility.settingsMCPSection == "harness.settings.mcp")
    #expect(
      HarnessMonitorAccessibility.settingsMCPRegistryHostToggle
        == "harness.settings.mcp.registry-host"
    )
    #expect(HarnessMonitorAccessibility.settingsMCPStatus == "harness.settings.mcp.status")
    #expect(HarnessMonitorAccessibility.mcpBanner == "harness.content.mcp.banner")

    let contentToolbar = try sourceFile(named: "ContentToolbarItems.swift")
    let contentChrome = try sourceFile(named: "ContentChromeSupport.swift")
    let settingsMCP = try sourceFile(named: "SettingsMCPSection.swift")

    #expect(!contentToolbar.contains("mcpToolbarStatus"))
    #expect(contentChrome.contains("MCPStatusBanner(status: mcpStatus)"))
    #expect(settingsMCP.contains("settingsMCPStatus"))
  }

  @Test("Menu bar extra identifiers match UI-test mirror")
  func menuBarExtraIdentifiersMirror() {
    #expect(HarnessMonitorAccessibility.menuBarExtra == "harness.menu-bar.extra")
    #expect(
      HarnessMonitorAccessibility.menuBarConnectionStatus
        == "harness.menu-bar.status.connection"
    )
    #expect(
      HarnessMonitorAccessibility.menuBarSessionStatus
        == "harness.menu-bar.status.sessions"
    )
    #expect(
      HarnessMonitorAccessibility.menuBarDecisionStatus == "harness.menu-bar.status.decisions"
    )
    #expect(
      HarnessMonitorAccessibility.menuBarSupervisorStatus
        == "harness.menu-bar.status.supervisor"
    )
    #expect(
      HarnessMonitorAccessibility.menuBarOpenMonitor
        == "harness.menu-bar.action.open-monitor"
    )
    #expect(
      HarnessMonitorAccessibility.menuBarOpenWorkspace
        == "harness.menu-bar.action.open-workspace"
    )
    #expect(
      HarnessMonitorAccessibility.menuBarOpenSettings
        == "harness.menu-bar.action.open-settings"
    )
    #expect(HarnessMonitorAccessibility.menuBarRefresh == "harness.menu-bar.action.refresh")
    #expect(
      HarnessMonitorAccessibility.menuBarSupervisorToggle
        == "harness.menu-bar.action.supervisor-toggle"
    )
    #expect(
      HarnessMonitorAccessibility.menuBarSupervisorCheckNow
        == "harness.menu-bar.action.supervisor-check-now"
    )
    #expect(
      HarnessMonitorAccessibility.menuBarRunWhenClosed
        == "harness.menu-bar.action.run-when-closed"
    )
    #expect(HarnessMonitorAccessibility.menuBarQuit == "harness.menu-bar.action.quit")
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

  @Test("Workspace create pane keeps MCP-tracked provider controls eagerly mounted")
  func workspaceCreatePaneKeepsMCPTrackedProviderControlsEagerlyMounted() throws {
    let createForm = try sourceFile(named: "WorkspaceWindowView+CreateForm.swift")
    let terminalCreateForm = try sourceFile(named: "WorkspaceWindowView+CreateFormTerminal.swift")

    #expect(
      createForm.contains("Keep MCP-tracked controls instantiated even while this pane scrolls."))
    #expect(
      !createForm.contains(
        "LazyVStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXL)")
    )
    #expect(
      !terminalCreateForm.contains(
        "LazyVStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing)")
    )
  }

  @Test("Workspace create pane config pills use wrapping flow layout")
  func workspaceCreatePaneConfigPillsUseWrappingFlowLayout() throws {
    let createFormPills = try sourceFile(named: "WorkspaceWindowView+CreateFormPills.swift")

    #expect(createFormPills.contains("AgentsConfigPillFlow("))
  }

  @Test("Workspace create pane resets scroll position when selected")
  func workspaceCreatePaneResetsScrollPositionWhenSelected() throws {
    let createForm = try sourceFile(named: "WorkspaceWindowView+CreateForm.swift")
    let workspaceLayout = try sourceFile(named: "WorkspaceWindowView+Layout.swift")

    #expect(createForm.contains("ScrollViewReader"))
    #expect(createForm.contains("scrollProxy.scrollTo(Self.topAnchorID, anchor: .top)"))
    #expect(workspaceLayout.contains(".id(detailIdentity)"))
    #expect(workspaceLayout.contains("let detailIdentity = scrollContainerIdentity"))
  }

  @Test("Sidebar session rows stay MCP-selectable")
  func sidebarSessionRowsStayMCPSelectable() throws {
    let sidebarSections = try sourceFile(named: "SidebarView+Sections.swift")
    let sidebarView = try sourceFile(named: "SidebarView.swift")

    #expect(sidebarSections.contains("HarnessMonitorAccessibility.sessionRow(session.sessionId)"))
    #expect(sidebarSections.contains("activateSessionRow(session.sessionId)"))
    #expect(sidebarView.contains("store.selectSessionFromList(sessionID)"))
    #expect(sidebarSections.contains(".harnessMCPRow("))
  }

  @Test("Agents runtime identifiers match UI-test mirror")
  func agentsRuntimeIdentifiersMirror() {
    #expect(
      HarnessMonitorAccessibility.agentRuntimeStrip("worker-codex")
        == "harness.workspace.detail.runtime.strip.worker-codex"
    )
    #expect(
      HarnessMonitorAccessibility.agentRuntimeWatchdog("worker-codex")
        == "harness.workspace.detail.runtime.watchdog.worker-codex"
    )
    #expect(
      HarnessMonitorAccessibility.agentRuntimePendingPermissions("worker-codex")
        == "harness.workspace.detail.runtime.pending-permissions.worker-codex"
    )
    #expect(
      HarnessMonitorAccessibility.agentRuntimeDeadline("worker-codex")
        == "harness.workspace.detail.runtime.deadline.worker-codex"
    )
    #expect(
      HarnessMonitorAccessibility.agentRuntimeDisclosure("worker-codex")
        == "harness.workspace.detail.runtime.disclosure.worker-codex"
    )
    #expect(
      HarnessMonitorAccessibility.agentRuntimeDisclosureContent("worker-codex")
        == "harness.workspace.detail.runtime.disclosure-content.worker-codex"
    )
    #expect(
      HarnessMonitorAccessibility.agentRuntimeWatchdogAccessibilityState
        == "harness.workspace.detail.runtime.watchdog.accessibility.state"
    )
    #expect(
      HarnessMonitorAccessibility.toolCallTimelineAccessibilityState
        == "harness.window.workspace.tool-call-timeline.accessibility.state"
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

}
