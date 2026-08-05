import XCTest

@testable import HarnessMonitor
@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

final class AppOpenAnythingRouteExecutorTests: XCTestCase {
  func testDashboardRouteOpensDashboardRoute() {
    XCTAssertEqual(
      steps(for: .dashboardRoute(.reviews)),
      [.openDashboard(.reviews)]
    )
  }

  func testSettingsSectionOpensSettingsSection() {
    XCTAssertEqual(
      steps(for: .settingsSection(rawValue: "General")),
      [.openSettings(rawValue: "General")]
    )
  }

  func testSessionHitOpensDashboardAgent() {
    XCTAssertEqual(
      steps(for: .session(sessionID: "sess-1")),
      [.openDashboardAgent(.session(sessionID: "sess-1"))]
    )
  }

  func testTaskBoardItemWithOwnerRoutesToExactBoardItem() {
    XCTAssertEqual(
      steps(for: .taskBoardItem(id: "item-1", sessionID: "sess-1", workItemID: "task-1")),
      [.openDashboardTaskBoard(.item(itemID: "item-1"))]
    )
  }

  func testTaskBoardItemWithoutOwnerStillPreservesExactBoardItem() {
    XCTAssertEqual(
      steps(for: .taskBoardItem(id: "item-1", sessionID: nil, workItemID: nil)),
      [.openDashboardTaskBoard(.item(itemID: "item-1"))]
    )
  }

  func testDecisionWithOwnerRoutesToDashboardDecision() {
    XCTAssertEqual(
      steps(for: .decision(id: "decision-1", sessionID: "sess-1")),
      [.openDashboardAgent(.decision(decisionID: "decision-1"))]
    )
  }

  func testDecisionWithoutOwnerStillPreservesExactDecision() {
    XCTAssertEqual(
      steps(for: .decision(id: "decision-1", sessionID: nil)),
      [.openDashboardAgent(.decision(decisionID: "decision-1"))]
    )
  }

  func testReviewSelectsPrAndOpensReviewsRoute() {
    XCTAssertEqual(
      steps(for: .review(pullRequestID: "repo#42")),
      [
        .selectDashboardReview(pullRequestID: "repo#42"),
        .openDashboard(.reviews),
      ]
    )
  }

  func testLoadedSessionAgentRoutesToDashboardAgent() {
    XCTAssertEqual(
      steps(for: .loadedSession(.agent(sessionID: "sess-1", agentID: "agent-1"))),
      [.openDashboardAgent(.sessionAgent(sessionID: "sess-1", agentID: "agent-1"))]
    )
  }

  func testLoadedSessionTaskRoutesToDashboardBoard() {
    XCTAssertEqual(
      steps(for: .loadedSession(.task(sessionID: "sess-1", taskID: "task-9"))),
      [.openDashboardTaskBoard(.loadedSessionTask(sessionID: "sess-1", taskID: "task-9"))]
    )
  }

  func testLoadedSessionTimelineOpensDashboardAudit() {
    let target = OpenAnythingLoadedSessionTimelineTarget(
      entry: TimelineEntry(
        entryId: "entry-1",
        recordedAt: "2026-08-05T08:00:00Z",
        kind: "agent.progress",
        sessionId: "sess-1",
        agentId: "agent-1",
        taskId: "task-1",
        summary: "Progress",
        payload: .object(["message": .string("Working")])
      )
    )
    XCTAssertEqual(
      steps(for: .loadedSession(.timeline(target))),
      [.openDashboardAudit(.sessionTimeline(.init(target)))]
    )
  }

  func testWindowSettingsOpensSettingsWindow() {
    XCTAssertEqual(
      steps(for: .window(.settings)),
      [.openWindow(.settings)]
    )
  }

  func testWindowDashboardOpensDashboardWindow() {
    XCTAssertEqual(
      steps(for: .window(.dashboard)),
      [.openWindow(.dashboard)]
    )
  }

  // MARK: - OpenAnythingAction mappings

  func testActionNewSessionPresentsSessionSheet() {
    XCTAssertEqual(
      steps(for: .action(.newSession)),
      [.presentNewSessionSheet]
    )
  }

  func testActionNewTaskPresentsTaskSheet() {
    XCTAssertEqual(
      steps(for: .action(.newTask)),
      [.presentNewTaskSheet]
    )
  }

  func testActionAttachExternalSessionTriggersAttach() {
    XCTAssertEqual(
      steps(for: .action(.attachExternalSession)),
      [.openWindow(.dashboard), .attachExternalSession]
    )
  }

  func testDashboardAndSessionWindowsHostSharedSheetsInPlace() {
    XCTAssertFalse(
      openAnythingRequiresDashboardPresentationHost(
        targetWindowID: HarnessMonitorWindowID.dashboard,
        presentationTargetCanHostSharedSheet: true
      )
    )
    XCTAssertFalse(
      openAnythingRequiresDashboardPresentationHost(
        targetWindowID: "session-current",
        presentationTargetCanHostSharedSheet: true
      )
    )
  }

  func testOffSpaceMissingAndSettingsWindowsRequireDashboardSheetHost() {
    XCTAssertTrue(
      openAnythingRequiresDashboardPresentationHost(
        targetWindowID: "session-off-space",
        presentationTargetCanHostSharedSheet: false
      )
    )
    XCTAssertTrue(
      openAnythingRequiresDashboardPresentationHost(
        targetWindowID: nil,
        presentationTargetCanHostSharedSheet: false
      )
    )
    XCTAssertTrue(
      openAnythingRequiresDashboardPresentationHost(
        targetWindowID: HarnessMonitorWindowID.settings,
        presentationTargetCanHostSharedSheet: false
      )
    )
  }

  func testExplicitPaletteDismissalsRelinquishPanelKey() {
    XCTAssertTrue(openAnythingShouldRelinquishPanelKey(after: .userCanceled))
    XCTAssertTrue(
      openAnythingShouldRelinquishPanelKey(after: .hitExecuted(recordID: "action"))
    )
    XCTAssertFalse(openAnythingShouldRelinquishPanelKey(after: .windowResignedKey))
    XCTAssertFalse(openAnythingShouldRelinquishPanelKey(after: .scenePhaseBackground))
  }

  func testExplicitDismissalsCanRestoreOriginatingWindowDirectly() {
    XCTAssertTrue(openAnythingShouldRestorePresentationTarget(after: .userCanceled))
    XCTAssertTrue(
      openAnythingShouldRestorePresentationTarget(after: .hitExecuted(recordID: "action"))
    )
    XCTAssertFalse(openAnythingShouldRestorePresentationTarget(after: .windowResignedKey))
    XCTAssertFalse(openAnythingShouldRestorePresentationTarget(after: .scenePhaseBackground))
  }

  func testOnlyVisibleCurrentSpaceWindowCanReceiveRestoredKeyStatus() {
    XCTAssertTrue(
      openAnythingCanRestorePresentationTarget(
        isVisible: true,
        isMiniaturized: false,
        isOnActiveSpace: true
      )
    )
    XCTAssertFalse(
      openAnythingCanRestorePresentationTarget(
        isVisible: true,
        isMiniaturized: false,
        isOnActiveSpace: false
      )
    )
    XCTAssertFalse(
      openAnythingCanRestorePresentationTarget(
        isVisible: false,
        isMiniaturized: false,
        isOnActiveSpace: true
      )
    )
    XCTAssertFalse(
      openAnythingCanRestorePresentationTarget(
        isVisible: true,
        isMiniaturized: true,
        isOnActiveSpace: true
      )
    )
  }

  func testWindowBackedStepsRequireApplicationActivation() {
    let steps: [OpenAnythingRoutingStep] = [
      .presentNewSessionSheet,
      .presentNewTaskSheet,
      .openWindow(.dashboard),
      .openDashboard(.taskBoard),
      .openDashboardAgent(.session(sessionID: "session-1")),
      .openDashboardTaskBoard(.item(itemID: "task-1")),
      .openDashboardAudit(.auditEvent(eventID: "event-1")),
      .openSettings(rawValue: "mcp"),
    ]

    for step in steps {
      XCTAssertTrue(openAnythingRoutingStepRequiresApplicationActivation(step), "\(step)")
    }
  }

  func testBackgroundStepsDoNotActivateApplication() {
    let steps: [OpenAnythingRoutingStep] = [
      .attachExternalSession,
      .refresh,
      .refreshDiagnostics,
      .reconnectDaemon,
      .copyDiagnostics,
      .selectDashboardReview(pullRequestID: "pr-1"),
      .openExternalURL(URL(string: "https://example.com")!),
      .revealInFinder(URL(fileURLWithPath: "/tmp/example")),
    ]

    for step in steps {
      XCTAssertFalse(openAnythingRoutingStepRequiresApplicationActivation(step), "\(step)")
    }
  }

  func testActionOpenDashboardOpensDashboardWindow() {
    XCTAssertEqual(
      steps(for: .action(.openDashboard)),
      [.openWindow(.dashboard)]
    )
  }

  func testActionOpenTaskBoardOpensBoardRoute() {
    XCTAssertEqual(
      steps(for: .action(.openTaskBoard)),
      [.openDashboard(.taskBoard)]
    )
  }

  func testActionOpenReviewsOpensReviewsRoute() {
    XCTAssertEqual(
      steps(for: .action(.openReviews)),
      [.openDashboard(.reviews)]
    )
  }

  func testActionOpenNotificationsOpensAuditRoute() {
    XCTAssertEqual(
      steps(for: .action(.openNotifications)),
      [.openDashboard(.audit)]
    )
  }

  func testActionOpenAuditOpensAuditRoute() {
    XCTAssertEqual(
      steps(for: .action(.openAudit)),
      [.openDashboard(.audit)]
    )
  }

  func testActionOpenPolicyCanvasOpensPolicyRoute() {
    XCTAssertEqual(
      steps(for: .action(.openPolicyCanvas)),
      [.openDashboard(.policyCanvas)]
    )
  }

  func testActionOpenDiagnosticsOpensDiagnosticsRoute() {
    XCTAssertEqual(
      steps(for: .action(.openDiagnostics)),
      [.openDashboard(.diagnostics)]
    )
  }

  func testActionOpenDebuggingOpensDebuggingRoute() {
    XCTAssertEqual(
      steps(for: .action(.openDebugging)),
      [.openDashboard(.debugging)]
    )
  }

  func testActionRefreshTriggersRefresh() {
    XCTAssertEqual(
      steps(for: .action(.refresh)),
      [.refresh]
    )
  }

  func testActionRefreshDiagnosticsNavigatesThenRefreshes() {
    XCTAssertEqual(
      steps(for: .action(.refreshDiagnostics)),
      [
        .openDashboard(.diagnostics),
        .refreshDiagnostics,
      ]
    )
  }

  func testActionReconnectDaemonReconnects() {
    XCTAssertEqual(
      steps(for: .action(.reconnectDaemon)),
      [.reconnectDaemon]
    )
  }

  func testActionCopyDiagnosticsCopies() {
    XCTAssertEqual(
      steps(for: .action(.copyDiagnostics)),
      [.copyDiagnostics]
    )
  }

  func testActionSettingsOpensSettingsWindow() {
    XCTAssertEqual(
      steps(for: .action(.settings)),
      [.openWindow(.settings)]
    )
  }

  func testActionOpenMCPSettingsOpensMCPSection() {
    XCTAssertEqual(
      steps(for: .action(.openMCPSettings)),
      [.openSettings(rawValue: "mcp")]
    )
  }

  func testActionOpenDatabaseSettingsOpensDatabaseSection() {
    XCTAssertEqual(
      steps(for: .action(.openDatabaseSettings)),
      [.openSettings(rawValue: "database")]
    )
  }

  /// Every `OpenAnythingAction` case must produce at least one step. A new case
  /// without a mapping would assert here even if a future contributor forgot
  /// to add a per-case test above.
  func testEveryOpenAnythingActionProducesSteps() {
    for action in OpenAnythingAction.allCases {
      let result = OpenAnythingRouteExecutor.steps(for: .action(action))
      XCTAssertFalse(
        result.isEmpty,
        "Action \(action) produced no steps"
      )
    }
  }

  // MARK: - Deep-link steps

  func testDeepLinkOpenExternalURLEquality() {
    let url = URL(string: "https://github.com/example/repo/pull/42")!
    XCTAssertEqual(
      OpenAnythingRoutingStep.openExternalURL(url),
      .openExternalURL(url)
    )
    XCTAssertNotEqual(
      OpenAnythingRoutingStep.openExternalURL(url),
      .openExternalURL(URL(string: "https://example.com")!)
    )
  }

  func testDeepLinkRevealInFinderEquality() {
    let url = URL(fileURLWithPath: "/tmp/worktrees/session-1")
    XCTAssertEqual(
      OpenAnythingRoutingStep.revealInFinder(url),
      .revealInFinder(url)
    )
    XCTAssertNotEqual(
      OpenAnythingRoutingStep.revealInFinder(url),
      .revealInFinder(URL(fileURLWithPath: "/tmp/elsewhere"))
    )
  }

  private func steps(for target: OpenAnythingTarget) -> [OpenAnythingRoutingStep] {
    OpenAnythingRouteExecutor.steps(for: target)
  }
}
