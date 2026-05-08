import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class SessionWindowVoiceOverTests: HarnessMonitorUITestCase {
  private static let decisionSeedEnvKey = "HARNESS_MONITOR_SUPERVISOR_SEED_DECISIONS"
  private static let previewScenarioKey = "HARNESS_MONITOR_PREVIEW_SCENARIO"
  private static let dashboardLandingScenario = "dashboard-landing"
  private static let uiTestsKey = "HARNESS_MONITOR_UI_TESTS"
  private static let mainWindowWidthKey = "HARNESS_MONITOR_UI_MAIN_WINDOW_WIDTH"
  private static let previewSessionID = "sess1234"
  private static let decisionSummary = "Seeded session-window decision"

  func testSessionWindowKeepsInspectorAndFilteredSelectionAccessible() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: [
        Self.previewScenarioKey: Self.dashboardLandingScenario,
        Self.uiTestsKey: "1",
        Self.mainWindowWidthKey: "1800",
        Self.decisionSeedEnvKey: makeSeededDecisionsPayload(),
      ]
    )

    let openRecentWindow = element(in: app, identifier: Accessibility.openRecentRoot)
    XCTAssertTrue(waitForElement(openRecentWindow, timeout: Self.uiTimeout))

    let sessionRowIdentifier = Accessibility.openRecentSessionRow(Self.previewSessionID)
    XCTAssertTrue(
      waitForButtonReady(
        in: app,
        identifier: sessionRowIdentifier,
        timeout: Self.uiTimeout
      ),
      "Preview launch should expose the seeded session row."
    )
    tapButton(in: app, identifier: sessionRowIdentifier)

    let sessionWindow = element(in: app, identifier: Accessibility.sessionWindowShell)
    XCTAssertTrue(waitForElement(sessionWindow, timeout: Self.uiTimeout))

    let sidebar = element(in: app, identifier: Accessibility.sessionWindowSidebar)
    XCTAssertTrue(waitForElement(sidebar, timeout: Self.actionTimeout))

    let focusModeToggle = app.checkBoxes["Focus Mode"].firstMatch
    XCTAssertTrue(waitForElement(focusModeToggle, timeout: Self.actionTimeout))

    let statusMenu = button(in: app, identifier: Accessibility.sessionWindowStatusMenu)
    XCTAssertTrue(waitForElement(statusMenu, timeout: Self.actionTimeout))
    XCTAssertTrue(statusMenu.label.contains("Session status"))

    XCTAssertFalse(
      mainWindow(in: app).searchFields.firstMatch.exists,
      "Chunk 5 should not keep a toolbar search field once decision filtering lives in the sidebar."
    )

    let inspector = element(in: app, identifier: Accessibility.sessionWindowInspector)
    app.typeKey("i", modifierFlags: [.command, .option])
    XCTAssertFalse(
      inspector.exists,
      "Inspector should stay unavailable until a decision is selected."
    )

    let decisionRow = sessionSidebarDecisionRow(in: app)
    XCTAssertTrue(waitForElement(decisionRow, timeout: Self.actionTimeout))
    XCTAssertTrue(tapElementReliably(in: app, element: decisionRow))

    app.typeKey("i", modifierFlags: [.command, .option])
    XCTAssertTrue(
      waitForElement(inspector, timeout: Self.actionTimeout),
      "Inspector should open after selecting a decision."
    )

    let closeButton = button(
      in: app,
      identifier: Accessibility.sessionWindowInspectorCloseButton
    )
    XCTAssertTrue(waitForElement(closeButton, timeout: Self.actionTimeout))
    XCTAssertEqual(closeButton.label, "Close inspector")

    let filterField = mainWindow(in: app).textFields["Filter decisions"].firstMatch
    XCTAssertTrue(waitForElement(filterField, timeout: Self.actionTimeout))
    filterField.tap()
    filterField.typeText("does-not-match")

    let hiddenNotice = staticText(in: app, containing: "Decision hidden by")
    XCTAssertTrue(
      waitForElement(hiddenNotice, timeout: Self.actionTimeout),
      "Filtering should keep the selected decision truthful instead of falling into an unavailable state."
    )
    XCTAssertFalse(
      app.staticTexts["No Decision Selected"].firstMatch.exists,
      "Filtering the selected decision should not fall back to a generic unavailable placeholder."
    )

    let clearFilters = button(in: app, title: "Clear Filters")
    XCTAssertTrue(waitForElement(clearFilters, timeout: Self.actionTimeout))
    clearFilters.tap()

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { !hiddenNotice.exists },
      "Clearing filters should dismiss the hidden-selection notice."
    )

    closeButton.tap()
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { !inspector.exists },
      "Close inspector should hide the custom side pane."
    )
  }

  private func makeSeededDecisionsPayload() -> String {
    let decision: [String: Any] = [
      "id": "session-window-ui-seed",
      "severity": "warn",
      "ruleID": "stuck-agent",
      "sessionID": Self.previewSessionID,
      "summary": Self.decisionSummary,
      "contextJSON": "{\"agentID\":\"agent-session-window-ui\"}",
      "suggestedActionsJSON": "[]",
    ]
    return serializeJSONObject(["decisions": [decision]])
  }

  private func serializeJSONObject(_ object: Any) -> String {
    guard
      let data = try? JSONSerialization.data(withJSONObject: object, options: []),
      let string = String(data: data, encoding: .utf8)
    else {
      return "{\"decisions\":[]}"
    }
    return string
  }

  private func sessionSidebarDecisionRow(in app: XCUIApplication) -> XCUIElement {
    let summaryPrefix = "Seeded session"
    let summaryPredicate = NSPredicate(
      format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
      summaryPrefix,
      summaryPrefix
    )
    let sidebar = element(in: app, identifier: Accessibility.sessionWindowSidebar)
    let cellMatch = sidebar.descendants(matching: .cell)
      .matching(summaryPredicate)
      .firstMatch
    if cellMatch.exists {
      return cellMatch
    }
    return sidebar.descendants(matching: .staticText)
      .matching(summaryPredicate)
      .firstMatch
  }

  private func staticText(in app: XCUIApplication, containing text: String) -> XCUIElement {
    let predicate = NSPredicate(
      format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
      text,
      text
    )
    return mainWindow(in: app).descendants(matching: .staticText)
      .matching(predicate)
      .firstMatch
  }
}
