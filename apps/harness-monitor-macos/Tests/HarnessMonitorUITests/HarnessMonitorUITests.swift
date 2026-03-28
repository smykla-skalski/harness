import XCTest

@MainActor
final class HarnessMonitorUITests: XCTestCase {
  private enum Accessibility {
    static let sidebarToggleButton = "monitor.toolbar.sidebar-toggle"
    static let preferencesButton = "monitor.toolbar.preferences"
    static let refreshButton = "monitor.toolbar.refresh"
    static let sidebarRoot = "monitor.sidebar.root"
    static let previewSessionRow = "monitor.sidebar.session.sess-monitor"
    static let sidebarEmptyState = "monitor.sidebar.empty-state"
    static let sidebarSessionList = "monitor.sidebar.session-list"
    static let activeFilterButton = "monitor.sidebar.filter.active"
    static let allFilterButton = "monitor.sidebar.filter.all"
    static let endedFilterButton = "monitor.sidebar.filter.ended"
    static let onboardingCard = "monitor.board.onboarding-card"
    static let sessionsBoardRoot = "monitor.board.root"
    static let recentSessionsCard = "monitor.board.recent-sessions-card"
    static let contentRoot = "monitor.content.root"
    static let inspectorRoot = "monitor.inspector.root"
    static let inspectorEmptyState = "monitor.inspector.empty-state"
    static let sessionInspectorCard = "monitor.inspector.session-card"
    static let observerInspectorCard = "monitor.inspector.observer-card"
    static let observeSummaryButton = "monitor.session.observe.summary"
  }

  private static let launchModeKey = "HARNESS_MONITOR_LAUNCH_MODE"
  private static let uiTimeout: TimeInterval = 10

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testPreviewModeLoadsDashboardAndOpensCockpit() throws {
    let app = launch(mode: "preview")

    let sessionRow = app.buttons.matching(identifier: Accessibility.previewSessionRow).firstMatch
    let sessionRowExists = sessionRow.waitForExistence(timeout: Self.uiTimeout)
    XCTAssertTrue(sessionRowExists)

    tapButton(in: app, identifier: Accessibility.previewSessionRow)

    let observeSummaryButton = app.buttons
      .matching(identifier: Accessibility.observeSummaryButton)
      .firstMatch
    XCTAssertTrue(observeSummaryButton.waitForExistence(timeout: Self.uiTimeout))
  }

  func testEmptyModeShowsOnboardingCard() throws {
    let app = launch(mode: "empty")

    let onboardingTitleExists = app.staticTexts["Bring The Monitor Online"]
      .waitForExistence(timeout: Self.uiTimeout)
    XCTAssertTrue(onboardingTitleExists)
    XCTAssertTrue(app.buttons["Start Daemon"].exists)

    let sidebarEmptyState = element(in: app, identifier: Accessibility.sidebarEmptyState)
    let sidebarRoot = element(in: app, identifier: Accessibility.sidebarRoot)
    XCTAssertTrue(sidebarEmptyState.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(sidebarRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertFalse(element(in: app, identifier: Accessibility.sidebarSessionList).exists)
    XCTAssertEqual(sidebarRoot.descendants(matching: .scrollView).count, 0)
    XCTAssertEqual(sidebarRoot.descendants(matching: .scrollBar).count, 0)

    let activeFilter = element(in: app, identifier: Accessibility.activeFilterButton)
    XCTAssertTrue(activeFilter.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertEqual(activeFilter.value as? String, "selected accent-on-light")
    XCTAssertEqual(
      element(in: app, identifier: Accessibility.allFilterButton).value as? String,
      "not selected ink-on-panel"
    )
    XCTAssertEqual(
      element(in: app, identifier: Accessibility.endedFilterButton).value as? String,
      "not selected ink-on-panel"
    )
  }

  func testToolbarOpensPreferencesSheet() throws {
    let app = launch(mode: "preview")

    let preferencesButton = toolbarButton(in: app, identifier: Accessibility.preferencesButton)
    let preferencesButtonExists = preferencesButton.waitForExistence(timeout: Self.uiTimeout)
    XCTAssertTrue(preferencesButtonExists)

    preferencesButton.tap()

    let preferencesTitleExists = app.staticTexts["Daemon Preferences"]
      .waitForExistence(timeout: Self.uiTimeout)
    XCTAssertTrue(preferencesTitleExists)
  }

  func testObserveSummaryIsAvailableInSessionCockpit() throws {
    let app = launch(mode: "preview")

    let sessionRow = app.buttons.matching(identifier: Accessibility.previewSessionRow).firstMatch
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))
    tapButton(in: app, identifier: Accessibility.previewSessionRow)

    let tasks = app.staticTexts["Tasks"]
    let signals = app.staticTexts["Signals"]
    XCTAssertTrue(tasks.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(signals.waitForExistence(timeout: Self.uiTimeout))

    let observeSummaryButton = app.buttons
      .matching(identifier: Accessibility.observeSummaryButton)
      .firstMatch
    XCTAssertTrue(observeSummaryButton.waitForExistence(timeout: Self.uiTimeout))
    tapButton(in: app, identifier: Accessibility.observeSummaryButton)

    XCTAssertTrue(tasks.exists)
    XCTAssertTrue(signals.exists)
  }

  func testToolbarSurvivesSidebarToggle() throws {
    let app = launch(mode: "preview")

    let sidebarToggle = toolbarButton(
      in: app,
      identifier: Accessibility.sidebarToggleButton
    )
    let refreshButton = toolbarButton(in: app, identifier: Accessibility.refreshButton)
    let preferencesButton = toolbarButton(
      in: app,
      identifier: Accessibility.preferencesButton
    )
    let sessionRow = app.buttons.matching(identifier: Accessibility.previewSessionRow).firstMatch

    XCTAssertTrue(sidebarToggle.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(refreshButton.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(preferencesButton.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(refreshButton.isHittable)
    XCTAssertTrue(preferencesButton.isHittable)

    sidebarToggle.tap()

    XCTAssertTrue(waitUntil { !sessionRow.exists || !sessionRow.isHittable })
    XCTAssertTrue(refreshButton.exists)
    XCTAssertTrue(preferencesButton.exists)
    XCTAssertTrue(refreshButton.isHittable)
    XCTAssertTrue(preferencesButton.isHittable)

    sidebarToggle.tap()

    XCTAssertTrue(waitUntil { sessionRow.exists && sessionRow.isHittable })
    XCTAssertTrue(refreshButton.isHittable)
    XCTAssertTrue(preferencesButton.isHittable)
    refreshButton.tap()
    XCTAssertTrue(preferencesButton.exists)
  }

  func testEmptyModeCardsSpanTheirColumns() throws {
    let app = launch(mode: "empty")

    let boardRoot = element(in: app, identifier: Accessibility.sessionsBoardRoot)
    let onboardingCard = element(in: app, identifier: Accessibility.onboardingCard)
    let recentSessionsCard = element(in: app, identifier: Accessibility.recentSessionsCard)
    let inspectorRoot = element(in: app, identifier: Accessibility.inspectorRoot)
    let inspectorEmptyState = element(in: app, identifier: Accessibility.inspectorEmptyState)

    XCTAssertTrue(boardRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(onboardingCard.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(recentSessionsCard.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(inspectorRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(inspectorEmptyState.waitForExistence(timeout: Self.uiTimeout))

    assertFillsColumn(
      child: onboardingCard,
      in: boardRoot,
      expectedHorizontalInset: 24,
      tolerance: 8
    )
    assertFillsColumn(
      child: recentSessionsCard,
      in: boardRoot,
      expectedHorizontalInset: 24,
      tolerance: 8
    )
    XCTAssertEqual(recentSessionsCard.frame.width, onboardingCard.frame.width, accuracy: 8)
    assertFillsColumn(
      child: inspectorEmptyState,
      in: inspectorRoot,
      expectedHorizontalInset: 18,
      tolerance: 8
    )
  }

  func testInspectorCardsFillTheirColumn() throws {
    let app = launch(mode: "preview")

    let inspectorRoot = element(in: app, identifier: Accessibility.inspectorRoot)
    let sessionInspectorCard = element(in: app, identifier: Accessibility.sessionInspectorCard)
    let sessionRow = app.buttons.matching(identifier: Accessibility.previewSessionRow).firstMatch

    XCTAssertTrue(inspectorRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))

    tapButton(in: app, identifier: Accessibility.previewSessionRow)

    XCTAssertTrue(sessionInspectorCard.waitForExistence(timeout: Self.uiTimeout))
    assertFillsColumn(
      child: sessionInspectorCard,
      in: inspectorRoot,
      expectedHorizontalInset: 18,
      tolerance: 8
    )
  }

  private func launch(mode: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment[Self.launchModeKey] = mode
    app.launch()
    XCTAssertTrue(waitUntil(timeout: Self.uiTimeout) { app.state == .runningForeground })
    app.activate()
    XCTAssertTrue(waitUntil(timeout: Self.uiTimeout) { app.state == .runningForeground })
    return app
  }

  private func tapButton(in app: XCUIApplication, identifier: String) {
    let deadline = Date().addingTimeInterval(Self.uiTimeout)

    while Date() < deadline {
      app.activate()

      let button = app.buttons.matching(identifier: identifier).firstMatch
      if button.waitForExistence(timeout: 0.5), button.isHittable {
        button.tap()
        return
      }

      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    XCTFail("Failed to tap button \(identifier)")
  }

  private func element(in app: XCUIApplication, identifier: String) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(identifier: identifier)
      .firstMatch
  }

  private func toolbarButton(in app: XCUIApplication, identifier: String) -> XCUIElement {
    app.buttons.matching(identifier: identifier).firstMatch
  }

  private func waitUntil(
    timeout: TimeInterval = 5,
    pollInterval: TimeInterval = 0.1,
    condition: @escaping () -> Bool
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() {
        return true
      }
      RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
    }
    return condition()
  }

  private func assertFillsColumn(
    child: XCUIElement,
    in container: XCUIElement,
    expectedHorizontalInset: CGFloat,
    tolerance: CGFloat
  ) {
    XCTAssertGreaterThan(child.frame.width, container.frame.width * 0.9)
    XCTAssertEqual(
      child.frame.minX,
      container.frame.minX + expectedHorizontalInset,
      accuracy: tolerance
    )
    XCTAssertEqual(
      child.frame.maxX,
      container.frame.maxX - expectedHorizontalInset,
      accuracy: tolerance
    )
  }
}
