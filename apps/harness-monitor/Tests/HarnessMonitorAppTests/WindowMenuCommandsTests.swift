import XCTest

@testable import HarnessMonitor
@testable import HarnessMonitorUIPreviewable

@MainActor
final class WindowMenuCommandsTests: XCTestCase {
  func testDashboardWindowTitleStaysStable() {
    XCTAssertEqual(WindowMenuCommands.mainTitle, "Dashboard")
  }

  func testMainCommandSetDoesNotIncludeDecisionMenu() throws {
    let commandSetSource = try harnessSourceFile(named: "App/HarnessMonitorMainCommandSet.swift")

    XCTAssertFalse(commandSetSource.contains("DecisionCommands()"))
  }

  func testSessionWindowCommandsAreAbsentFromMainCommandSet() throws {
    let commandSetSource = try harnessSourceFile(named: "App/HarnessMonitorMainCommandSet.swift")

    XCTAssertFalse(commandSetSource.contains("NewSessionCommand"))
    XCTAssertFalse(commandSetSource.contains("RecentSessionsCommand"))
    XCTAssertFalse(commandSetSource.contains("SessionCreateCommands"))
    XCTAssertFalse(commandSetSource.contains("SessionWindowCycleCommands"))
    XCTAssertFalse(commandSetSource.contains("SessionCommands"))
    XCTAssertFalse(commandSetSource.contains("presentOpenAnythingSessions"))
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

  func testGoCommandsPreferSharedWindowNavigation() throws {
    let source = try harnessSourceFile(named: "Commands/GoCommands.swift")

    XCTAssertTrue(source.contains("@FocusedValue(\\.windowNavigation)"))
    XCTAssertFalse(source.contains("@FocusedValue(\\.sessionNavigation)"))
    XCTAssertTrue(source.contains("windowNavigation?.canGoBack ?? false"))
    XCTAssertTrue(source.contains("windowNavigation?.canGoForward ?? false"))
    XCTAssertTrue(source.contains("windowNavigation?.navigateBack()"))
    XCTAssertTrue(source.contains("windowNavigation?.navigateForward()"))
    XCTAssertFalse(source.contains("await windowNavigation?.navigateBack()"))
    XCTAssertFalse(source.contains("await windowNavigation?.navigateForward()"))
    XCTAssertTrue(source.contains("displayState.canNavigateBack"))
    XCTAssertTrue(source.contains("displayState.canNavigateForward"))
  }

  func testTaskLaneHelpDoesNotAdvertiseCommandT() throws {
    let source = try uiPreviewableSourceFile(named: "Views/Sessions/SessionTaskLaneViews.swift")

    XCTAssertTrue(source.contains("⌥⌘T"))
    XCTAssertFalse(source.contains("(⌘T)"))
  }

  func testWindowMenuOnlyReopensDashboard() throws {
    let windowCommandsSource = try harnessSourceFile(named: "Commands/WindowMenuCommands.swift")

    XCTAssertTrue(windowCommandsSource.contains("openWindow.openHarnessDashboardWindow()"))
    XCTAssertFalse(windowCommandsSource.contains("New Tab"))
    XCTAssertFalse(windowCommandsSource.contains("sessionNavigation"))
    XCTAssertFalse(windowCommandsSource.contains("presentedSheet"))
  }

  func testViewMenuShortcutsStayExclusiveAcrossTextSizeAndCanvasZoomScopes() throws {
    let source = try harnessSourceFile(named: "App/HarnessMonitorAppCommands.swift")

    XCTAssertTrue(source.contains("private var hasPolicyCanvasZoomFocus: Bool"))
    XCTAssertTrue(source.contains("if hasPolicyCanvasZoomFocus {"))
    XCTAssertTrue(
      source.contains("Button(\"Decrease Text Size\", action: decreaseTextSize)\n          .disabled(true)")
    )
    XCTAssertTrue(
      source.contains(
        "Button(\"Decrease Text Size\", action: decreaseTextSize)"
          + "\n          .keyboardShortcut(\"-\", modifiers: .command)"
      )
    )
    XCTAssertTrue(source.contains("if let zoomFocus = policyCanvasZoomFocus {"))
    XCTAssertTrue(
      source.contains("zoomFocus.dispatcher.performZoomOut()")
    )
    XCTAssertTrue(
      source.contains(
        "Button(\"Reset Zoom\") {"
          + "\n          zoomFocus.dispatcher.performResetZoom()"
          + "\n        }"
          + "\n        .keyboardShortcut(\"0\", modifiers: .command)"
      )
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
      .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitor")
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
      .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }

}
