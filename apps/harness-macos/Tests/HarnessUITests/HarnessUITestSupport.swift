import XCTest

enum HarnessUITestAccessibility {
  static let appChromeRoot = "harness.app.chrome"
  static let appChromeState = "harness.app.chrome.state"
  static let daemonCard = "harness.sidebar.daemon-card"
  static let daemonCardFrame = "harness.sidebar.daemon-card.frame"
  static let sidebarShellFrame = "harness.sidebar.shell.frame"
  static let preferencesButton = "harness.toolbar.preferences"
  static let refreshButton = "harness.toolbar.refresh"
  static let sidebarStartButton = "harness.sidebar.action.start"
  static let sidebarInstallButton = "harness.sidebar.action.install"
  static let sidebarStartButtonFrame = "harness.sidebar.action.start.frame"
  static let sidebarInstallButtonFrame = "harness.sidebar.action.install.frame"
  static let sidebarRoot = "harness.sidebar.root"
  static let sidebarProjectsBadge = "harness.sidebar.daemon-badge.projects"
  static let sidebarSessionsBadge = "harness.sidebar.daemon-badge.sessions"
  static let sidebarLaunchdBadge = "harness.sidebar.daemon-badge.launchd"
  static let sidebarProjectsBadgeFrame = "harness.sidebar.daemon-badge.projects.frame"
  static let sidebarSessionsBadgeFrame = "harness.sidebar.daemon-badge.sessions.frame"
  static let sidebarLaunchdBadgeFrame = "harness.sidebar.daemon-badge.launchd.frame"
  static let previewProjectHeader = "harness.sidebar.project-header.project-6ccf8d0a"
  static let previewProjectHeaderFrame = "harness.sidebar.project-header.project-6ccf8d0a.frame"
  static let previewSessionRow = "harness.sidebar.session.sess-harness"
  static let sidebarEmptyState = "harness.sidebar.empty-state"
  static let sidebarSessionList = "harness.sidebar.session-list"
  static let sidebarSessionListContent = "harness.sidebar.session-list.content"
  static let sidebarFiltersCard = "harness.sidebar.filters"
  static let sidebarSearchField = "harness.sidebar.search"
  static let sidebarClearFiltersButton = "harness.sidebar.filters.clear"
  static let activeFilterButton = "harness.sidebar.filter.active"
  static let allFilterButton = "harness.sidebar.filter.all"
  static let endedFilterButton = "harness.sidebar.filter.ended"
  static let openWorkChip = "harness.sidebar.focus-chip.openwork"
  static let blockedChip = "harness.sidebar.focus-chip.blocked"
  static let observedChip = "harness.sidebar.focus-chip.observed"
  static let idleChip = "harness.sidebar.focus-chip.idle"
  static let onboardingCard = "harness.board.onboarding-card"
  static let onboardingStartButton = "harness.board.action.start"
  static let onboardingInstallButton = "harness.board.action.install"
  static let onboardingRefreshButton = "harness.board.action.refresh"
  static let onboardingStartButtonFrame = "harness.board.action.start.frame"
  static let onboardingInstallButtonFrame = "harness.board.action.install.frame"
  static let onboardingRefreshButtonFrame = "harness.board.action.refresh.frame"
  static let sessionsBoardRoot = "harness.board.root"
  static let recentSessionsCard = "harness.board.recent-sessions-card"
  static let trackedProjectsCard = "harness.board.metric.tracked-projects"
  static let indexedSessionsCard = "harness.board.metric.indexed-sessions"
  static let openWorkCard = "harness.board.metric.open-work"
  static let blockedCard = "harness.board.metric.blocked"
  static let inspectorRoot = "harness.inspector.root"
  static let inspectorEmptyState = "harness.inspector.empty-state"
  static let sessionInspectorCard = "harness.inspector.session-card"
  static let taskInspectorCard = "harness.inspector.task-card"
  static let agentInspectorCard = "harness.inspector.agent-card"
  static let signalInspectorCard = "harness.inspector.signal-card"
  static let observerInspectorCard = "harness.inspector.observer-card"
  static let actionActorPicker = "harness.inspector.action-actor"
  static let removeAgentButton = "harness.inspector.remove-agent"
  static let signalSendButton = "harness.inspector.signal-send"
  static let observeSummaryButton = "harness.session.observe.summary"
  static let endSessionButton = "harness.session.action.end"
  static let pendingLeaderTransferCard = "harness.session.pending-transfer"
  static let taskUICard = "harness.session.task.task-ui"
  static let taskRoutingCard = "harness.session.task.task-routing"
  static let leaderAgentCard = "harness.session.agent.leader-claude"
  static let workerAgentCard = "harness.session.agent.worker-codex"
  static let preferencesRoot = "harness.preferences.root"
  static let preferencesState = "harness.preferences.state"
  static let preferencesPanel = "harness.preferences.panel"
  static let preferencesSidebar = "harness.preferences.sidebar"
  static let preferencesBackButton = "harness.preferences.nav.back"
  static let preferencesForwardButton = "harness.preferences.nav.forward"
  static let preferencesTitle = "harness.preferences.title"
  static let preferencesThemeModePicker = "harness.preferences.theme-mode"
  static let preferencesThemeStylePicker = "harness.preferences.theme-style"
  static let preferencesGeneralSection = "harness.preferences.section.general"
  static let preferencesConnectionSection = "harness.preferences.section.connection"
  static let preferencesDiagnosticsSection = "harness.preferences.section.diagnostics"
  static let preferencesEndpointCard = "harness.preferences.metric.endpoint"
  static let preferencesVersionCard = "harness.preferences.metric.version"
  static let preferencesLaunchdCard = "harness.preferences.metric.launchd"
  static let preferencesCachedSessionsCard = "harness.preferences.metric.cached-sessions"
  static let reconnectButton = "harness.preferences.action.reconnect"
  static let refreshDiagnosticsButton = "harness.preferences.action.refresh-diagnostics"
  static let startDaemonButton = "harness.preferences.action.start-daemon"
  static let installLaunchAgentButton = "harness.preferences.action.install-launch-agent"
  static let removeLaunchAgentButton = "harness.preferences.action.remove-launch-agent"
}

@MainActor
class HarnessUITestCase: XCTestCase {
  static let launchModeKey = "HARNESS_LAUNCH_MODE"
  static let uiTestHostBundleIdentifier = "io.aiharness.app.ui-testing"
  static let uiTimeout: TimeInterval = 10

  override func setUpWithError() throws {
    continueAfterFailure = false
  }
}

extension HarnessUITestCase {
  func mainWindow(in app: XCUIApplication) -> XCUIElement {
    let mainWindow = app.windows.matching(identifier: "main").firstMatch
    if mainWindow.exists {
      return mainWindow
    }
    return app.windows.firstMatch
  }

  func launch(mode: String) -> XCUIApplication {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    terminateIfRunning(app)
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launchEnvironment["HARNESS_UI_TESTS"] = "1"
    app.launchEnvironment[Self.launchModeKey] = mode
    app.launch()
    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) {
        if app.state != .runningForeground {
          app.activate()
        }

        return app.state == .runningForeground || self.mainWindow(in: app).exists
      }
    )
    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) {
        let window = self.mainWindow(in: app)
        app.activate()
        return
          window.exists
          && window.frame.width > 0
          && window.frame.height > 0
      }
    )
    return app
  }

  func terminateIfRunning(_ app: XCUIApplication) {
    switch app.state {
    case .runningForeground, .runningBackground:
      app.terminate()
      XCTAssertTrue(
        waitUntil(timeout: Self.uiTimeout) {
          app.state == .notRunning
        }
      )
    case .notRunning, .unknown:
      break
    @unknown default:
      break
    }
  }

  func tapButton(in app: XCUIApplication, identifier: String) {
    let deadline = Date.now.addingTimeInterval(Self.uiTimeout)

    while Date.now < deadline {
      app.activate()

      let button = button(in: app, identifier: identifier)
      if button.waitForExistence(timeout: 0.5) {
        if button.isHittable {
          button.tap()
          return
        }

        if let coordinate = centerCoordinate(in: app, for: button) {
          coordinate.tap()
          return
        }
      }

      RunLoop.current.run(until: Date.now.addingTimeInterval(0.2))
    }

    XCTFail("Failed to tap button \(identifier)")
  }

  func tapElement(in app: XCUIApplication, identifier: String) {
    let deadline = Date.now.addingTimeInterval(Self.uiTimeout)

    while Date.now < deadline {
      app.activate()

      let target = element(in: app, identifier: identifier)
      if target.waitForExistence(timeout: 0.5) {
        if target.isHittable {
          target.tap()
          return
        }

        if let coordinate = centerCoordinate(in: app, for: target) {
          coordinate.tap()
          return
        }
      }

      RunLoop.current.run(until: Date.now.addingTimeInterval(0.2))
    }

    XCTFail("Failed to tap element \(identifier)")
  }

  func selectMenuOption(
    in app: XCUIApplication,
    controlIdentifier: String,
    optionTitle: String
  ) {
    let control = element(in: app, identifier: controlIdentifier)
    XCTAssertTrue(control.waitForExistence(timeout: Self.uiTimeout))
    tapElement(in: app, identifier: controlIdentifier)

    let menuItem = app.descendants(matching: .menuItem).matching(
      NSPredicate(format: "title == %@", optionTitle)
    ).firstMatch
    XCTAssertTrue(menuItem.waitForExistence(timeout: Self.uiTimeout))
    menuItem.tap()
  }

  func element(in app: XCUIApplication, identifier: String) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(identifier: identifier)
      .firstMatch
  }

  func button(in app: XCUIApplication, identifier: String) -> XCUIElement {
    let mainWindowButton = mainWindow(in: app)
      .descendants(matching: .button)
      .matching(identifier: identifier)
      .firstMatch
    if mainWindowButton.exists {
      return mainWindowButton
    }
    return app.buttons.matching(identifier: identifier).firstMatch
  }

  func frameElement(in app: XCUIApplication, identifier: String) -> XCUIElement {
    app.otherElements.matching(identifier: identifier).firstMatch
  }

  func toolbarButton(in app: XCUIApplication, identifier: String) -> XCUIElement {
    let mainWindowToolbarButton = mainWindow(in: app)
      .toolbars
      .buttons
      .matching(identifier: identifier)
      .firstMatch
    if mainWindowToolbarButton.exists {
      return mainWindowToolbarButton
    }
    return app.toolbars.buttons.matching(identifier: identifier).firstMatch
  }

  func toolbarButton(in app: XCUIApplication, index: Int) -> XCUIElement {
    let windowToolbarButtons = mainWindow(in: app).toolbars.buttons
    if windowToolbarButtons.count > index {
      return windowToolbarButtons.element(boundBy: index)
    }
    return app.toolbars.buttons.element(boundBy: index)
  }

  func sidebarToggleButton(in app: XCUIApplication) -> XCUIElement {
    let toolbarButtons = mainWindow(in: app).toolbars.buttons.allElementsBoundByIndex
    if let button = toolbarButtons.first(where: { button in
      let identifier = button.identifier
      return
        identifier != HarnessUITestAccessibility.refreshButton
        && identifier != HarnessUITestAccessibility.preferencesButton
    }) {
      return button
    }

    return toolbarButton(in: app, index: 0)
  }

  func dragUp(in app: XCUIApplication, element: XCUIElement, distanceRatio: CGFloat = 0.32) {
    let window = mainWindow(in: app)
    XCTAssertTrue(window.waitForExistence(timeout: Self.uiTimeout))

    let origin = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
    let x = element.frame.midX - window.frame.minX
    let startY = element.frame.maxY - window.frame.minY - 36
    let minimumEndY = element.frame.minY - window.frame.minY + 36
    let targetEndY = startY - (element.frame.height * distanceRatio)
    let endY = max(minimumEndY, targetEndY)

    let start = origin.withOffset(CGVector(dx: x, dy: startY))
    let end = origin.withOffset(CGVector(dx: x, dy: endY))
    start.press(forDuration: 0.05, thenDragTo: end)
  }

  func confirmationDialogButton(in app: XCUIApplication, title: String) -> XCUIElement {
    let alertButton = app.sheets.buttons[title]
    if alertButton.exists {
      return alertButton
    }
    return app.dialogs.buttons[title]
  }

  func dismissConfirmationDialog(in app: XCUIApplication) {
    let cancelButton = confirmationDialogButton(in: app, title: "Cancel")
    XCTAssertTrue(cancelButton.waitForExistence(timeout: Self.uiTimeout))
    cancelButton.tap()
  }

  func attachWindowScreenshot(
    in app: XCUIApplication,
    named name: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let attachment = XCTAttachment(screenshot: mainWindow(in: app).screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func attachAppHierarchy(
    in app: XCUIApplication,
    named name: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let attachment = XCTAttachment(string: app.debugDescription)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func waitUntil(
    timeout: TimeInterval = 5,
    pollInterval: TimeInterval = 0.1,
    condition: @escaping () -> Bool
  ) -> Bool {
    let deadline = Date.now.addingTimeInterval(timeout)
    while Date.now < deadline {
      if condition() {
        return true
      }
      RunLoop.current.run(until: Date.now.addingTimeInterval(pollInterval))
    }
    return condition()
  }

  private func centerCoordinate(
    in app: XCUIApplication,
    for element: XCUIElement
  ) -> XCUICoordinate? {
    let window = mainWindow(in: app)
    guard window.waitForExistence(timeout: 0.5) else {
      return nil
    }

    let origin = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
    let dx = element.frame.midX - window.frame.minX
    let dy = element.frame.midY - window.frame.minY
    return origin.withOffset(CGVector(dx: dx, dy: dy))
  }

  func assertFillsColumn(
    child: XCUIElement,
    in container: XCUIElement,
    expectedHorizontalInset: CGFloat,
    tolerance: CGFloat
  ) {
    let expectedWidth = container.frame.width - (expectedHorizontalInset * 2)
    XCTAssertEqual(child.frame.width, expectedWidth, accuracy: tolerance * 2)
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

  func assertSameRow(_ elements: [XCUIElement], tolerance: CGFloat) {
    guard let first = elements.first else {
      XCTFail("No elements provided")
      return
    }

    for element in elements.dropFirst() {
      XCTAssertEqual(element.frame.minY, first.frame.minY, accuracy: tolerance)
    }
  }

  func assertEqualHeights(_ elements: [XCUIElement], tolerance: CGFloat) {
    guard let first = elements.first else {
      XCTFail("No elements provided")
      return
    }

    for element in elements.dropFirst() {
      XCTAssertEqual(element.frame.height, first.frame.height, accuracy: tolerance)
    }
  }
}
