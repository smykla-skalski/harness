import XCTest

@testable import HarnessMonitor
@testable import HarnessMonitorUIPreviewable

@MainActor
final class WindowMenuCommandsTests: XCTestCase {
  func testOpenRecentSessionTitleStaysStable() {
    XCTAssertEqual(WindowMenuCommands.mainTitle, "Dashboard")
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

  func testCommandNAlwaysPresentsNewSessionSheetOnTrackedWindows() throws {
    let source = try harnessSourceFile(named: "Commands/NewSessionCommand.swift")
    let commandSetSource = try harnessSourceFile(named: "App/HarnessMonitorMainCommandSet.swift")

    XCTAssertTrue(
      commandSetSource.contains(
        "NewSessionCommand(\n      store: store,\n      keyWindowObserver: keyWindowObserver,\n      windowCommandRouting: windowCommandRouting"
      )
    )
    XCTAssertTrue(source.contains("Button(\"New Session\")"))
    XCTAssertTrue(source.contains("CommandGroup(replacing: .newItem)"))
    XCTAssertTrue(source.contains(".keyboardShortcut(\"n\", modifiers: [.command])"))
    XCTAssertTrue(source.contains("let keyWindowObserver: KeyWindowObserver"))
    XCTAssertTrue(source.contains("keyWindowObserver.snapshot.keyWindowIdentifier"))
    XCTAssertTrue(source.contains("keyWindowIdentifier == HarnessMonitorWindowID.dashboard"))
    XCTAssertTrue(source.contains("keyWindowIdentifier?.hasPrefix(\"session-\") == true"))
    XCTAssertTrue(source.contains("windowCommandRouting.activeScope == .main"))
    XCTAssertTrue(source.contains("windowCommandRouting.activeScope == .session"))
    XCTAssertTrue(source.contains("store.presentedSheet = .newSession"))
    XCTAssertFalse(source.contains("sessionCreate?.primaryKind"))
    XCTAssertFalse(source.contains("guard store.connectionState == .online else"))
  }

  func testSessionCreateCommandsExposeMenuOnlyCodexAgentEntry() throws {
    let commandsSource = try harnessSourceFile(named: "Commands/SessionCreateCommands.swift")
    let commandSetSource = try harnessSourceFile(named: "App/HarnessMonitorMainCommandSet.swift")
    let routingStateSource = try uiPreviewableSourceFile(named: "Support/WindowNavigationState.swift")
    let shellSource = try harnessSourceFile(named: "App/HarnessMonitorWindowSceneShell.swift")
    let focusedValuesSource = try uiPreviewableSourceFile(named: "Support/SessionFocusedValues.swift")
    let sessionFocusedValuesSource = try uiPreviewableSourceFile(
      named: "Views/Sessions/SessionWindowView+FocusedValues.swift")
    let sheetRouterSource = try uiPreviewableSourceFile(named: "Views/Shared/HarnessMonitorSheetRouter.swift")
    let storeEnumsSource = try kitSourceFile(named: "Stores/HarnessMonitorStore+Enums.swift")
    let routeModelSource = try kitSourceFile(named: "Models/SessionRouteSelection.swift")

    XCTAssertTrue(
      commandSetSource.contains(
        "SessionCreateCommands(\n      store: store,\n      windowCommandRouting: windowCommandRouting"
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
    XCTAssertFalse(commandSetSource.contains("@FocusedValue(\\.sessionCreateContext)"))
    XCTAssertFalse(focusedValuesSource.contains("SessionCreateContext"))
    XCTAssertFalse(focusedValuesSource.contains("sessionCreateContext"))
    XCTAssertFalse(sessionFocusedValuesSource.contains("focusedSceneValue(\\.sessionCreateContext"))
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
    XCTAssertTrue(selectionSource.contains("public var primaryCreateKind: SessionCreateKind"))
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
    XCTAssertTrue(sidebarSource.contains("let shortcut = kind.createShortcut"))
    XCTAssertTrue(sidebarSource.contains("kind.createShortcut"))
    XCTAssertFalse(sidebarSource.contains("displayedCreateShortcut"))
    XCTAssertTrue(sidebarSource.contains("displayedShortcut.hint"))
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

  func testSessionCreateCommandsKeepExplicitEntriesVisible() throws {
    let source = try harnessSourceFile(named: "Commands/SessionCreateCommands.swift")

    XCTAssertTrue(source.contains("Button(\"New Agent\")"))
    XCTAssertTrue(source.contains("Button(\"New Task\")"))
    XCTAssertTrue(source.contains("Button(\"New Decision\")"))
    XCTAssertFalse(source.contains("shouldShowExplicitCommand"))
    XCTAssertFalse(source.contains("let primaryKind = sessionCreate?.primaryKind"))
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

    XCTAssertTrue(source.contains("Shared tabbing identifier unavailable"))
    XCTAssertTrue(source.contains("falling back to standalone windows"))
    XCTAssertTrue(source.contains("window.tabbingMode = .automatic"))
  }

  func testDashboardCommandsUseSharedTabOpenHelper() throws {
    let windowCommandsSource = try harnessSourceFile(named: "Commands/WindowMenuCommands.swift")
    let recentCommandsSource = try harnessSourceFile(named: "Commands/RecentSessionsCommand.swift")

    XCTAssertTrue(windowCommandsSource.contains("openWindow.openHarnessDashboardWindow()"))
    XCTAssertTrue(recentCommandsSource.contains("openWindow.openHarnessDashboardWindow()"))
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
    XCTAssertTrue(source.contains("openWindow.openHarnessDashboardWindow()"))
    XCTAssertTrue(source.contains("Show Dashboard"))
  }

  func testViewMenuShortcutsStayExclusiveAcrossTextSizeAndCanvasZoomScopes() throws {
    let source = try harnessSourceFile(named: "App/HarnessMonitorAppCommands.swift")

    XCTAssertTrue(source.contains("private var hasPolicyCanvasZoomFocus: Bool"))
    XCTAssertTrue(source.contains("if hasPolicyCanvasZoomFocus {"))
    XCTAssertTrue(
      source.contains("Button(\"Decrease Text Size\", action: decreaseTextSize)\n          .disabled(true)")
    )
    XCTAssertTrue(
      source.contains("Button(\"Decrease Text Size\", action: decreaseTextSize)\n          .keyboardShortcut(\"-\", modifiers: .command)")
    )
    XCTAssertTrue(source.contains("if let zoomFocus = policyCanvasZoomFocus {"))
    XCTAssertTrue(
      source.contains("zoomFocus.dispatcher.performZoomOut()")
    )
    XCTAssertTrue(
      source.contains("Button(\"Reset Zoom\") {\n          zoomFocus.dispatcher.performResetZoom()\n        }\n        .keyboardShortcut(\"0\", modifiers: .command)")
    )
    XCTAssertFalse(source.contains(".disabled(!canDecreaseTextSize || policyCanvasZoomFocus != nil)"))
    XCTAssertFalse(source.contains(".disabled(policyCanvasZoomFocus == nil)"))
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
