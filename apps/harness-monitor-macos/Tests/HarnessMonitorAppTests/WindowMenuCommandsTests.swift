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

  func testGoCommandsUseSessionFocusedNavigationOnly() throws {
    let source = try harnessSourceFile(named: "Commands/GoCommands.swift")

    XCTAssertTrue(source.contains("@FocusedValue(\\.sessionNavigation)"))
    XCTAssertFalse(source.contains("@FocusedValue(\\.windowNavigation)"))
    XCTAssertFalse(source.contains("workspaceNavigation"))
    XCTAssertFalse(source.contains("WindowNavigationScope"))
  }

  func testTaskLaneHelpDoesNotAdvertiseCommandT() throws {
    let source = try uiPreviewableSourceFile(named: "Views/Sessions/SessionTaskLaneViews.swift")

    XCTAssertTrue(source.contains("⌥⌘T"))
    XCTAssertFalse(source.contains("(⌘T)"))
  }

  private func harnessSourceFile(named relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor-macos/Sources/HarnessMonitor")
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }

  private func uiPreviewableSourceFile(named relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
