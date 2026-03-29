import XCTest

enum HarnessMonitorUITestAccessibility {
  static let daemonCard = "monitor.sidebar.daemon-card"
  static let daemonCardFrame = "monitor.sidebar.daemon-card.frame"
  static let preferencesButton = "monitor.toolbar.preferences"
  static let refreshButton = "monitor.toolbar.refresh"
  static let sidebarStartButton = "monitor.sidebar.action.start"
  static let sidebarInstallButton = "monitor.sidebar.action.install"
  static let sidebarStartButtonFrame = "monitor.sidebar.action.start.frame"
  static let sidebarInstallButtonFrame = "monitor.sidebar.action.install.frame"
  static let sidebarRoot = "monitor.sidebar.root"
  static let sidebarProjectsBadge = "monitor.sidebar.daemon-badge.projects"
  static let sidebarSessionsBadge = "monitor.sidebar.daemon-badge.sessions"
  static let sidebarLaunchdBadge = "monitor.sidebar.daemon-badge.launchd"
  static let sidebarProjectsBadgeFrame = "monitor.sidebar.daemon-badge.projects.frame"
  static let sidebarSessionsBadgeFrame = "monitor.sidebar.daemon-badge.sessions.frame"
  static let sidebarLaunchdBadgeFrame = "monitor.sidebar.daemon-badge.launchd.frame"
  static let previewProjectHeader = "monitor.sidebar.project-header.project-6ccf8d0a"
  static let previewProjectHeaderFrame = "monitor.sidebar.project-header.project-6ccf8d0a.frame"
  static let previewSessionRow = "monitor.sidebar.session.sess-monitor"
  static let sidebarEmptyState = "monitor.sidebar.empty-state"
  static let sidebarSessionList = "monitor.sidebar.session-list"
  static let sidebarSessionListContent = "monitor.sidebar.session-list.content"
  static let activeFilterButton = "monitor.sidebar.filter.active"
  static let allFilterButton = "monitor.sidebar.filter.all"
  static let endedFilterButton = "monitor.sidebar.filter.ended"
  static let onboardingCard = "monitor.board.onboarding-card"
  static let onboardingStartButton = "monitor.board.action.start"
  static let onboardingInstallButton = "monitor.board.action.install"
  static let onboardingRefreshButton = "monitor.board.action.refresh"
  static let onboardingStartButtonFrame = "monitor.board.action.start.frame"
  static let onboardingInstallButtonFrame = "monitor.board.action.install.frame"
  static let onboardingRefreshButtonFrame = "monitor.board.action.refresh.frame"
  static let sessionsBoardRoot = "monitor.board.root"
  static let recentSessionsCard = "monitor.board.recent-sessions-card"
  static let trackedProjectsCard = "monitor.board.metric.tracked-projects"
  static let indexedSessionsCard = "monitor.board.metric.indexed-sessions"
  static let openWorkCard = "monitor.board.metric.open-work"
  static let blockedCard = "monitor.board.metric.blocked"
  static let inspectorRoot = "monitor.inspector.root"
  static let inspectorEmptyState = "monitor.inspector.empty-state"
  static let sessionInspectorCard = "monitor.inspector.session-card"
  static let taskInspectorCard = "monitor.inspector.task-card"
  static let agentInspectorCard = "monitor.inspector.agent-card"
  static let signalInspectorCard = "monitor.inspector.signal-card"
  static let observerInspectorCard = "monitor.inspector.observer-card"
  static let actionActorPicker = "monitor.inspector.action-actor"
  static let removeAgentButton = "monitor.inspector.remove-agent"
  static let signalSendButton = "monitor.inspector.signal-send"
  static let observeSummaryButton = "monitor.session.observe.summary"
  static let endSessionButton = "monitor.session.action.end"
  static let pendingLeaderTransferCard = "monitor.session.pending-transfer"
  static let taskUICard = "monitor.session.task.task-ui"
  static let taskRoutingCard = "monitor.session.task.task-routing"
  static let leaderAgentCard = "monitor.session.agent.leader-claude"
  static let workerAgentCard = "monitor.session.agent.worker-codex"
  static let preferencesRoot = "monitor.preferences.root"
  static let preferencesPanel = "monitor.preferences.panel"
  static let preferencesBackdrop = "monitor.preferences.backdrop"
  static let preferencesEndpointCard = "monitor.preferences.metric.endpoint"
  static let preferencesVersionCard = "monitor.preferences.metric.version"
  static let preferencesLaunchdCard = "monitor.preferences.metric.launchd"
  static let preferencesCachedSessionsCard = "monitor.preferences.metric.cached-sessions"
  static let reconnectButton = "monitor.preferences.action.reconnect"
  static let refreshDiagnosticsButton = "monitor.preferences.action.refresh-diagnostics"
  static let startDaemonButton = "monitor.preferences.action.start-daemon"
  static let installLaunchAgentButton = "monitor.preferences.action.install-launch-agent"
  static let removeLaunchAgentButton = "monitor.preferences.action.remove-launch-agent"
}

@MainActor
class HarnessMonitorUITestCase: XCTestCase {
  static let launchModeKey = "HARNESS_MONITOR_LAUNCH_MODE"
  static let uiTimeout: TimeInterval = 10

  override func setUpWithError() throws {
    continueAfterFailure = false
  }
}

extension HarnessMonitorUITestCase {
  func launch(mode: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["HARNESS_MONITOR_UI_TESTS"] = "1"
    app.launchEnvironment[Self.launchModeKey] = mode
    app.launch()
    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) {
        if app.state != .runningForeground {
          app.activate()
        }

        let window = app.windows.firstMatch
        if window.exists {
          self.raiseWindow(in: app)
        }

        return app.state == .runningForeground || window.exists
      }
    )
    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) {
        let window = app.windows.firstMatch
        app.activate()
        if window.exists {
          self.raiseWindow(in: app)
        }
        let title = app.staticTexts["Harness Monitor"]
        let sidebarRoot = self.element(
          in: app,
          identifier: HarnessMonitorUITestAccessibility.sidebarRoot
        )
        let sessionsBoardRoot = self.element(
          in: app,
          identifier: HarnessMonitorUITestAccessibility.sessionsBoardRoot
        )
        return
          window.exists
          && window.frame.width > 0
          && window.frame.height > 0
          && (title.exists || sidebarRoot.exists || sessionsBoardRoot.exists)
      }
    )
    return app
  }

  func raiseWindow(in app: XCUIApplication) {
    app.activate()

    let window = app.windows.firstMatch
    guard window.exists else {
      return
    }

    let titlebarPoint = window.coordinate(
      withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04)
    )
    titlebarPoint.tap()
  }

  func tapButton(in app: XCUIApplication, identifier: String) {
    let deadline = Date().addingTimeInterval(Self.uiTimeout)

    while Date() < deadline {
      app.activate()

      let button = app.buttons.matching(identifier: identifier).firstMatch
      if button.waitForExistence(timeout: 0.5) {
        if let coordinate = centerCoordinate(in: app, for: button) {
          coordinate.tap()
          return
        }

        if button.isHittable {
          button.tap()
          return
        }
      }

      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    XCTFail("Failed to tap button \(identifier)")
  }

  func tapElement(in app: XCUIApplication, identifier: String) {
    let deadline = Date().addingTimeInterval(Self.uiTimeout)

    while Date() < deadline {
      app.activate()

      let target = element(in: app, identifier: identifier)
      if target.waitForExistence(timeout: 0.5) {
        if let coordinate = centerCoordinate(in: app, for: target) {
          coordinate.tap()
          return
        }

        if target.isHittable {
          target.tap()
          return
        }
      }

      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    XCTFail("Failed to tap element \(identifier)")
  }

  func element(in app: XCUIApplication, identifier: String) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(identifier: identifier)
      .firstMatch
  }

  func frameElement(in app: XCUIApplication, identifier: String) -> XCUIElement {
    app.otherElements.matching(identifier: identifier).firstMatch
  }

  func toolbarButton(in app: XCUIApplication, identifier: String) -> XCUIElement {
    app.toolbars.buttons.matching(identifier: identifier).firstMatch
  }

  func toolbarButton(in app: XCUIApplication, index: Int) -> XCUIElement {
    app.toolbars.buttons.element(boundBy: index)
  }

  func sidebarToggleButton(in app: XCUIApplication) -> XCUIElement {
    let toolbarButtons = app.toolbars.buttons.allElementsBoundByIndex
    if let button = toolbarButtons.first(where: { button in
      let identifier = button.identifier
      return
        identifier != HarnessMonitorUITestAccessibility.refreshButton
        && identifier != HarnessMonitorUITestAccessibility.preferencesButton
    }) {
      return button
    }

    return app.toolbars.buttons.element(boundBy: 0)
  }

  func tapOutsidePreferencesPanel(in app: XCUIApplication) {
    let window = app.windows.firstMatch
    let panel = frameElement(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.preferencesPanel
    )
    XCTAssertTrue(window.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(panel.waitForExistence(timeout: Self.uiTimeout))

    let origin = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
    let leftSpace = panel.frame.minX - window.frame.minX
    let rightSpace = window.frame.maxX - panel.frame.maxX
    let preferredTapX: CGFloat =
      if leftSpace > 32 {
        leftSpace - 18
      } else if rightSpace > 32 {
        panel.frame.maxX - window.frame.minX + 18
      } else {
        18
      }
    let tapX = min(max(preferredTapX, 18), window.frame.width - 18)
    let tapY = min(max(panel.frame.midY - window.frame.minY, 18), window.frame.height - 18)

    origin.withOffset(CGVector(dx: tapX, dy: tapY)).tap()
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

  func waitUntil(
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

  private func centerCoordinate(
    in app: XCUIApplication,
    for element: XCUIElement
  ) -> XCUICoordinate? {
    let window = app.windows.firstMatch
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
