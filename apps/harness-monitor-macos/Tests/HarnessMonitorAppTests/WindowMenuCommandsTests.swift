import XCTest

@testable import HarnessMonitor
@testable import HarnessMonitorUIPreviewable

@MainActor
final class WindowMenuCommandsTests: XCTestCase {
  func testOpenRecentSessionTitleStaysStable() {
    XCTAssertEqual(WindowMenuCommands.mainTitle, "Open Recent Session")
  }

  func testNewTabCommandUsesCommandTContract() {
    XCTAssertEqual(WindowMenuCommands.newTabTitle, "New Tab")
    XCTAssertEqual(WindowMenuCommands.newTabShortcut, "t")
  }

  func testNewTabDestinationUsesFocusedSessionScene() {
    let sessionNavigation = SessionNavigationCommand(
      sessionID: "sess-alpha",
      canGoBack: false,
      canGoForward: false,
      goBack: {},
      goForward: {}
    )

    XCTAssertEqual(
      WindowMenuCommands.newTabDestination(sessionNavigation: sessionNavigation),
      .session("sess-alpha")
    )
  }

  func testNewTabDestinationFallsBackToNewSessionSheetWithoutFocusedSession() {
    XCTAssertEqual(
      WindowMenuCommands.newTabDestination(sessionNavigation: nil),
      .newSessionSheet
    )
  }

  func testDecisionCommandsExposeBulkActionMenuTitles() {
    XCTAssertEqual(DecisionCommands.menuTitle, "Decisions")
    XCTAssertEqual(DecisionCommands.dismissSelectedTitle, "Dismiss Selected")
    XCTAssertEqual(DecisionCommands.dismissVisibleTitle, "Dismiss All Visible")
    XCTAssertEqual(DecisionCommands.reopenBatchTitle, "Reopen Dismissed Batch")
  }
}
