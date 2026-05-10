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

  func testMainCommandSetDoesNotIncludeDecisionMenu() throws {
    let commandSetSource = try harnessSourceFile(named: "App/HarnessMonitorMainCommandSet.swift")

    XCTAssertFalse(commandSetSource.contains("DecisionCommands()"))
  }

  func testCommandNUsesFocusedSessionCreateContext() throws {
    let source = try harnessSourceFile(named: "Commands/NewSessionCommand.swift")
    let commandSetSource = try harnessSourceFile(named: "App/HarnessMonitorMainCommandSet.swift")

    XCTAssertTrue(commandSetSource.contains("@FocusedValue(\\.sessionCreateContext)"))
    XCTAssertTrue(
      commandSetSource.contains("NewSessionCommand(store: store, sessionCreate: sessionCreate)")
    )
    XCTAssertTrue(source.contains(".keyboardShortcut(\"n\", modifiers: [.command])"))
    XCTAssertTrue(source.contains("guard let kind = sessionCreate?.primaryKind"))
    XCTAssertTrue(source.contains("return sessionCreate.createAgent"))
    XCTAssertTrue(source.contains("return sessionCreate.createTask"))
    XCTAssertTrue(source.contains("return sessionCreate.createDecision"))
    XCTAssertTrue(source.contains("guard store.connectionState == .online else"))
    XCTAssertTrue(source.contains("store.presentedSheet = .newSession"))
  }

  func testSessionCreateCommandsExposeMenuOnlyCodexAgentEntry() throws {
    let commandsSource = try harnessSourceFile(named: "Commands/SessionCreateCommands.swift")
    let commandSetSource = try harnessSourceFile(named: "App/HarnessMonitorMainCommandSet.swift")
    let routingStateSource = try uiPreviewableSourceFile(named: "Support/WindowNavigationState.swift")
    let shellSource = try harnessSourceFile(named: "App/HarnessMonitorWindowSceneShell.swift")
    let focusedValuesSource = try uiPreviewableSourceFile(named: "Support/SessionFocusedValues.swift")
    let inspectorSource = try uiPreviewableSourceFile(named: "Views/Sessions/SessionWindowView+Inspector.swift")
    let sheetRouterSource = try uiPreviewableSourceFile(named: "Views/Shared/HarnessMonitorSheetRouter.swift")
    let storeEnumsSource = try kitSourceFile(named: "Stores/HarnessMonitorStore+Enums.swift")
    let routeModelSource = try kitSourceFile(named: "Models/SessionRouteSelection.swift")

    XCTAssertTrue(
      commandSetSource.contains(
        "SessionCreateCommands(\n      store: store,\n      windowCommandRouting: windowCommandRouting,\n      sessionCreate: sessionCreate"
      )
    )
    XCTAssertTrue(commandsSource.contains("let createCodexAgent = createCodexAction"))
    XCTAssertTrue(commandsSource.contains("Button(\"New Codex Agent\") { createCodexAgent?() }"))
    XCTAssertTrue(commandsSource.contains("guard windowCommandRouting.activeScope == .session else"))
    XCTAssertTrue(commandsSource.contains("return windowCommandRouting.activeSessionID"))
    XCTAssertTrue(commandsSource.contains("store.presentedSheet = .newCodexAgent(sessionID: sessionID)"))
    XCTAssertTrue(commandsSource.contains("store.requestSessionRouteCreate(kind.routeCreateEntryPoint"))
    XCTAssertTrue(commandsSource.contains("return .task"))
    XCTAssertTrue(commandsSource.contains("return .decision"))
    XCTAssertTrue(focusedValuesSource.contains("public let createCodexAgent: () -> Void"))
    XCTAssertTrue(inspectorSource.contains("createCodexAgent: { store.presentedSheet = .newCodexAgent(sessionID: token.sessionID) }"))
    XCTAssertTrue(sheetRouterSource.contains("case .newCodexAgent(let sessionID):"))
    XCTAssertTrue(sheetRouterSource.contains("NewCodexAgentSheet(store: store, sessionID: sessionID)"))
    XCTAssertTrue(storeEnumsSource.contains("case newCodexAgent(sessionID: String)"))
    XCTAssertTrue(routingStateSource.contains("public private(set) var activeSessionID: String?"))
    XCTAssertTrue(routingStateSource.contains("public func register(sessionID: String?, windowID: ObjectIdentifier)"))
    XCTAssertTrue(shellSource.contains("let sessionID: String?"))
    XCTAssertTrue(shellSource.contains("sessionID: sessionID"))
    XCTAssertTrue(routeModelSource.contains("case task"))
    XCTAssertTrue(routeModelSource.contains("case decision"))
  }

  func testSessionCreateShortcutsStaySharedAcrossMenuAndSidebarHints() throws {
    let commandsSource = try harnessSourceFile(named: "Commands/SessionCreateCommands.swift")
    let selectionSource = try uiPreviewableSourceFile(named: "Support/SessionWindowSelection.swift")
    let shortcutSource = try uiPreviewableSourceFile(named: "Support/KeyboardShortcutDescriptor.swift")
    let sidebarSource = try uiPreviewableSourceFile(named: "Views/Sessions/SessionSidebar+Sections.swift")

    XCTAssertTrue(selectionSource.contains("public var createShortcut: KeyboardShortcutDescriptor"))
    XCTAssertTrue(selectionSource.contains("public var createShortcutModifiers: EventModifiers"))
    XCTAssertTrue(
      selectionSource.contains(".init(modifiers: [.option, .command], keyEquivalent: \"a\", keyLabel: \"A\")")
    )
    XCTAssertTrue(
      selectionSource.contains(".init(modifiers: [.option, .command], keyEquivalent: \"t\", keyLabel: \"T\")")
    )
    XCTAssertTrue(
      selectionSource.contains(".init(modifiers: [.option, .command], keyEquivalent: \"d\", keyLabel: \"D\")")
    )
    XCTAssertTrue(shortcutSource.contains("case .control: \"⌃\""))
    XCTAssertTrue(shortcutSource.contains("case .shift: \"⇧\""))
    XCTAssertTrue(shortcutSource.contains("public func isRevealed(by activeModifiers: EventModifiers) -> Bool"))
    XCTAssertTrue(
      commandsSource.contains(
        "SessionCreateKind.agent.createShortcut.requiredEventModifiers"
      )
    )
    XCTAssertTrue(
      commandsSource.contains(
        "SessionCreateKind.task.createShortcut.requiredEventModifiers"
      )
    )
    XCTAssertTrue(commandsSource.contains("SessionCreateKind.decision.createShortcut.requiredEventModifiers"))
    XCTAssertFalse(commandsSource.contains("modifiers: [.command, .option]"))
    XCTAssertTrue(sidebarSource.contains("KeyboardShortcutLabel(\n        shortcut: kind.createShortcut"))
  }

  func testSharedPresentationModifiersKeepBindingsMountedAcrossKeyWindowLoss() throws {
    let sheetModifierSource = try uiPreviewableSourceFile(
      named: "Views/Shared/HarnessMonitorSheetModifier.swift"
    )
    let confirmationModifierSource = try uiPreviewableSourceFile(
      named: "Views/Shared/HarnessMonitorConfirmationDialogModifier.swift"
    )

    XCTAssertTrue(sheetModifierSource.contains("get: { isEnabled ? shellUI.presentedSheet : nil }"))
    XCTAssertTrue(
      sheetModifierSource.contains("if sheet == nil && isEnabled && shellUI.presentedSheet != nil")
    )
    XCTAssertFalse(sheetModifierSource.contains("if isEnabled {\n      content"))

    XCTAssertTrue(
      confirmationModifierSource.contains("get: { isEnabled && shellUI.pendingConfirmation != nil }")
    )
    XCTAssertTrue(
      confirmationModifierSource.contains(
        "if !isPresented && isEnabled && shellUI.pendingConfirmation != nil"
      )
    )
    XCTAssertFalse(confirmationModifierSource.contains("if isEnabled {\n      content"))
  }

  func testSessionCreateCommandsHideThePrimaryDuplicateEntry() {
    XCTAssertFalse(
      SessionCreateCommands.shouldShowExplicitCommand(for: .agent, primaryKind: .agent)
    )
    XCTAssertFalse(
      SessionCreateCommands.shouldShowExplicitCommand(for: .task, primaryKind: .task)
    )
    XCTAssertFalse(
      SessionCreateCommands.shouldShowExplicitCommand(for: .decision, primaryKind: .decision)
    )
    XCTAssertTrue(
      SessionCreateCommands.shouldShowExplicitCommand(for: .agent, primaryKind: .task)
    )
    XCTAssertTrue(
      SessionCreateCommands.shouldShowExplicitCommand(for: .task, primaryKind: nil)
    )
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
