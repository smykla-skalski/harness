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

  func testCommandNUsesFocusedSessionCreateContext() throws {
    let source = try harnessSourceFile(named: "Commands/NewSessionCommand.swift")
    let commandSetSource = try harnessSourceFile(named: "App/HarnessMonitorMainCommandSet.swift")

    XCTAssertTrue(commandSetSource.contains("NewSessionCommand(store: store)"))
    XCTAssertTrue(source.contains("@FocusedValue(\\.sessionCreateContext)"))
    XCTAssertTrue(source.contains(".keyboardShortcut(\"n\", modifiers: [.command])"))
    XCTAssertTrue(source.contains("guard let kind = sessionCreate?.primaryKind"))
    XCTAssertTrue(source.contains("case .agent: sessionCreate.createAgent()"))
    XCTAssertTrue(source.contains("case .task: sessionCreate.createTask()"))
    XCTAssertTrue(source.contains("case .decision: sessionCreate.createDecision()"))
    XCTAssertTrue(source.contains("store.presentedSheet = .newSession"))
  }

  func testSessionCreateCommandsExposeMenuOnlyCodexAgentEntry() throws {
    let commandsSource = try harnessSourceFile(named: "Commands/SessionCreateCommands.swift")
    let focusedValuesSource = try uiPreviewableSourceFile(named: "Support/SessionFocusedValues.swift")
    let inspectorSource = try uiPreviewableSourceFile(named: "Views/Sessions/SessionWindowView+Inspector.swift")
    let sheetRouterSource = try uiPreviewableSourceFile(named: "Views/Shared/HarnessMonitorSheetRouter.swift")
    let storeEnumsSource = try kitSourceFile(named: "Stores/HarnessMonitorStore+Enums.swift")

    XCTAssertTrue(commandsSource.contains("Button(\"New Codex Agent\") { sessionCreate?.createCodexAgent() }"))
    XCTAssertTrue(focusedValuesSource.contains("public let createCodexAgent: () -> Void"))
    XCTAssertTrue(inspectorSource.contains("createCodexAgent: { store.presentedSheet = .newCodexAgent(sessionID: token.sessionID) }"))
    XCTAssertTrue(sheetRouterSource.contains("case .newCodexAgent(let sessionID):"))
    XCTAssertTrue(sheetRouterSource.contains("NewCodexAgentSheet(store: store, sessionID: sessionID)"))
    XCTAssertTrue(storeEnumsSource.contains("case newCodexAgent(sessionID: String)"))
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

  func testSessionWindowTabbingAccessorHasFallbackWarning() throws {
    let source = try harnessSourceFile(named: "App/SessionWindowTabbing.swift")

    XCTAssertTrue(source.contains("Session tabbing identifier unavailable"))
    XCTAssertTrue(source.contains("falling back to standalone windows"))
    XCTAssertTrue(source.contains("window.tabbingMode = .automatic"))
  }

  func testSessionWindowCycleCommandsAreWiredAndUseCommandBacktick() throws {
    let commandSetSource = try harnessSourceFile(named: "App/HarnessMonitorMainCommandSet.swift")
    let cycleSource = try harnessSourceFile(named: "Commands/SessionWindowCycleCommands.swift")

    XCTAssertTrue(commandSetSource.contains("SessionWindowCycleCommands()"))
    XCTAssertTrue(cycleSource.contains("CommandGroup(after: .windowArrangement)"))
    XCTAssertTrue(cycleSource.contains(".keyboardShortcut(Self.cycleShortcut, modifiers: .command)"))
    XCTAssertTrue(
      cycleSource.contains(
        ".keyboardShortcut(Self.cycleShortcut, modifiers: [.command, .shift])"
      )
    )
    XCTAssertTrue(cycleSource.contains("SessionWindowCycler.cycle(direction: .forward)"))
    XCTAssertTrue(cycleSource.contains("SessionWindowCycler.cycle(direction: .backward)"))
    XCTAssertEqual(SessionWindowCycleCommands.cycleShortcut, "`")
  }

  func testRecentSessionsCommandBuildsFileSubmenu() throws {
    let source = try harnessSourceFile(named: "Commands/RecentSessionsCommand.swift")
    let commandSetSource = try harnessSourceFile(named: "App/HarnessMonitorMainCommandSet.swift")

    XCTAssertTrue(commandSetSource.contains("RecentSessionsCommand(store: store)"))
    XCTAssertTrue(source.contains("Menu(Self.menuTitle)"))
    XCTAssertTrue(source.contains("openWindow.openHarnessSessionWindow"))
    XCTAssertTrue(source.contains("HarnessMonitorWindowID.openRecent"))
    XCTAssertTrue(source.contains("Show Open Recent Window"))
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

  private func kitSourceFile(named relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor-macos/Sources/HarnessMonitorKit")
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
