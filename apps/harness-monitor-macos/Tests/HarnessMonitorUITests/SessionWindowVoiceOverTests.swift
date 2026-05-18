import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class SessionWindowVoiceOverTests: HarnessMonitorUITestCase {
  private static let decisionSeedEnvKey = "HARNESS_MONITOR_SUPERVISOR_SEED_DECISIONS"
  private static let previewScenarioKey = "HARNESS_MONITOR_PREVIEW_SCENARIO"
  private static let dashboardLandingScenario = "dashboard-landing"
  private static let uiTestsKey = "HARNESS_MONITOR_UI_TESTS"
  private static let mainWindowWidthKey = "HARNESS_MONITOR_UI_MAIN_WINDOW_WIDTH"
  private static let previewSessionID = Accessibility.previewSessionID
  private static let decisionSummary = "Seeded session-window decision"

  func testFocusModeKeepsRouteContentVisibleWithoutMirroringSidebarFooter() throws {
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
    XCTAssertTrue(waitForElement(in: app, openRecentWindow, timeout: Self.uiTimeout))

    let sessionRowIdentifier = Accessibility.openRecentSessionRow(Self.previewSessionID)
    XCTAssertTrue(
      waitForButtonReady(
        in: app,
        identifier: sessionRowIdentifier,
        timeout: Self.uiTimeout
      )
    )
    tapButton(in: app, identifier: sessionRowIdentifier)

    let sessionWindow = element(in: app, identifier: Accessibility.sessionWindowShell)
    XCTAssertTrue(waitForElement(in: app, sessionWindow, timeout: Self.uiTimeout))

    let sidebar = element(in: app, identifier: Accessibility.sessionWindowSidebar)
    XCTAssertTrue(waitForElement(in: app, sidebar, timeout: Self.actionTimeout))
    let statusSurface = element(in: app, identifier: Accessibility.sessionWindowStatusSurface)
    XCTAssertTrue(waitForElement(statusSurface, timeout: Self.actionTimeout))

    let overviewRoute = element(
      in: app,
      identifier: Accessibility.sessionWindowRoute("overview")
    )
    XCTAssertTrue(waitForElement(in: app, overviewRoute, timeout: Self.actionTimeout))
    XCTAssertTrue(tapElementReliably(in: app, element: overviewRoute))

    let focusModeToggle = button(
      in: app,
      identifier: Accessibility.sessionWindowFocusModeButton
    )
    XCTAssertTrue(waitForElement(in: app, focusModeToggle, timeout: Self.actionTimeout))
    XCTAssertTrue(tapElementReliably(in: app, element: focusModeToggle))
    XCTAssertTrue(
      waitUntil(in: app, timeout: Self.actionTimeout) { !sidebar.exists },
      "Focus mode should replace the split-shell chrome with a single focused surface."
    )
    XCTAssertTrue(
      waitUntil(in: app, timeout: Self.actionTimeout) { !statusSurface.exists },
      "Focus mode should not mirror the sidebar footer into the toolbar when the sidebar is hidden."
    )

    let openTasksMetric = staticText(in: app, containing: "Open tasks")
    XCTAssertTrue(
      waitForElement(in: app, openTasksMetric, timeout: Self.actionTimeout),
      "Focus mode should keep overview content visible instead of showing the empty placeholder."
    )
    XCTAssertFalse(
      app.staticTexts["Select an Item"].firstMatch.exists,
      "Focus mode should preserve route content instead of showing the generic empty-state prompt."
    )
  }

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

    let focusModeToggle = button(
      in: app,
      identifier: Accessibility.sessionWindowFocusModeButton
    )
    XCTAssertTrue(waitForElement(focusModeToggle, timeout: Self.actionTimeout))

    let statusSurface = element(in: app, identifier: Accessibility.sessionWindowStatusSurface)
    XCTAssertTrue(waitForElement(statusSurface, timeout: Self.actionTimeout))
    XCTAssertTrue(statusSurface.label.contains("Session status"))

    let filterField = mainWindow(in: app).searchFields.firstMatch
    XCTAssertTrue(
      waitForElement(filterField, timeout: Self.actionTimeout),
      "The unified session search bar should stay available from the session window."
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

  func testSessionToolbarHistoryButtonsNavigateRoutes() throws {
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
      )
    )
    tapButton(in: app, identifier: sessionRowIdentifier)

    let sessionWindow = element(in: app, identifier: Accessibility.sessionWindowShell)
    XCTAssertTrue(waitForElement(sessionWindow, timeout: Self.uiTimeout))

    let backButton = button(in: app, identifier: Accessibility.sessionNavigateBackButton)
    let forwardButton = button(in: app, identifier: Accessibility.sessionNavigateForwardButton)
    XCTAssertTrue(waitForElement(backButton, timeout: Self.actionTimeout))
    XCTAssertTrue(waitForElement(forwardButton, timeout: Self.actionTimeout))
    XCTAssertFalse(backButton.isEnabled)
    XCTAssertFalse(forwardButton.isEnabled)

    let timelineRoute = element(
      in: app,
      identifier: Accessibility.sessionWindowRoute("timeline")
    )
    XCTAssertTrue(waitForElement(timelineRoute, timeout: Self.actionTimeout))
    XCTAssertTrue(tapElementReliably(in: app, element: timelineRoute))

    let timelineNavigation = element(
      in: app,
      identifier: Accessibility.sessionTimelineNavigation
    )
    XCTAssertTrue(waitForElement(timelineNavigation, timeout: Self.actionTimeout))
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        backButton.isEnabled && !forwardButton.isEnabled
      },
      "Opening another route should enable back while forward stays unavailable."
    )

    backButton.tap()

    let openTasksMetric = staticText(in: app, containing: "Open tasks")
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        openTasksMetric.exists && !timelineNavigation.exists && !backButton.isEnabled
          && forwardButton.isEnabled
      },
      "Back should restore the overview route and enable forward navigation."
    )

    forwardButton.tap()

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        timelineNavigation.exists && backButton.isEnabled && !forwardButton.isEnabled
      },
      "Forward should return to the timeline route once back has been used."
    )
  }

  func testSessionWindowShowsSleepPreventionToolbarButton() throws {
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

    let sessionShell = window(in: app, containing: sessionWindow)
    let sleepButton = sessionShell.toolbars.buttons
      .matching(identifier: Accessibility.sleepPreventionButton)
      .firstMatch
    XCTAssertTrue(
      waitForElement(sleepButton, timeout: Self.actionTimeout),
      "Session windows should expose the sleep prevention toolbar button."
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
