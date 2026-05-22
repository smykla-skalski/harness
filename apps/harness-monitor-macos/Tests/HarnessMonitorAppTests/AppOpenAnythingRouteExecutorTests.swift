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

  func testPolicyCanvasLabActionIsGated() {
    XCTAssertEqual(
      steps(for: .action(.policyCanvasLab), showsPolicyCanvasLab: false),
      []
    )
    XCTAssertEqual(
      steps(for: .action(.policyCanvasLab), showsPolicyCanvasLab: true),
      [.openWindow(.policyCanvasLab)]
    )
  }

  private func steps(
    for target: OpenAnythingTarget,
    showsPolicyCanvasLab: Bool = true
  ) -> [OpenAnythingRoutingStep] {
    OpenAnythingRouteExecutor.steps(
      for: target,
      showsPolicyCanvasLab: showsPolicyCanvasLab
    )
  }
}
