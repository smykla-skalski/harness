import XCTest

@testable import HarnessMonitor
@testable import HarnessMonitorKit

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

  func testSessionHitOpensSessionWindow() {
    XCTAssertEqual(
      steps(for: .session(sessionID: "sess-1")),
      [.openSessionWindow(sessionID: "sess-1")]
    )
  }

  func testTaskBoardItemWithOwnerRoutesToSessionTask() {
    XCTAssertEqual(
      steps(for: .taskBoardItem(id: "item-1", sessionID: "sess-1", workItemID: "task-1")),
      [
        .requestSessionRoute(.task(sessionID: "sess-1", taskID: "task-1")),
        .openSessionWindow(sessionID: "sess-1"),
      ]
    )
  }

  func testTaskBoardItemWithoutOwnerFallsBackToDashboardBoard() {
    XCTAssertEqual(
      steps(for: .taskBoardItem(id: "item-1", sessionID: nil, workItemID: nil)),
      [.openDashboard(.taskBoard)]
    )
  }

  func testDecisionWithOwnerRoutesToSessionDecision() {
    XCTAssertEqual(
      steps(for: .decision(id: "decision-1", sessionID: "sess-1")),
      [
        .requestSessionRoute(
          .decision(
            sessionID: "sess-1",
            decisionID: "decision-1",
            resetDecisionFilters: true
          )
        ),
        .openSessionWindow(sessionID: "sess-1"),
      ]
    )
  }

  func testDecisionWithoutOwnerFallsBackToDashboardBoard() {
    XCTAssertEqual(
      steps(for: .decision(id: "decision-1", sessionID: nil)),
      [
        .selectSupervisorDecision(id: "decision-1"),
        .openDashboard(.taskBoard),
      ]
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

  func testLoadedSessionEntitiesRouteToOwningSession() {
    XCTAssertEqual(
      steps(for: .loadedSession(.agent(sessionID: "sess-1", agentID: "agent-1"))),
      [
        .requestSessionRoute(.agent(sessionID: "sess-1", agentID: "agent-1")),
        .openSessionWindow(sessionID: "sess-1"),
      ]
    )
  }

  func testLoadedSessionTaskRoutesToOwningSession() {
    XCTAssertEqual(
      steps(for: .loadedSession(.task(sessionID: "sess-1", taskID: "task-9"))),
      [
        .requestSessionRoute(.task(sessionID: "sess-1", taskID: "task-9")),
        .openSessionWindow(sessionID: "sess-1"),
      ]
    )
  }

  func testLoadedSessionTimelineOpensSession() {
    XCTAssertEqual(
      steps(for: .loadedSession(.timeline(sessionID: "sess-1", entryID: "entry-1"))),
      [
        .requestSessionRoute(.timeline(sessionID: "sess-1", entryID: "entry-1")),
        .openSessionWindow(sessionID: "sess-1"),
      ]
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
      [.attachExternalSession]
    )
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
