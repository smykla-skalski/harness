import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

final class HarnessMonitorToolbarUITests: HarnessMonitorUITestCase {
  private let minimumToolbarControlDimension: CGFloat = 24

  private func distinctVisibleToolbarFrames(for query: XCUIElementQuery) -> Set<String> {
    var frames: [CGRect] = []
    let searchCount = min(query.count, 8)
    for index in 0..<searchCount {
      let element = query.element(boundBy: index)
      guard element.exists else {
        continue
      }
      let frame = roundedFrame(element.frame)
      // macOS toolbars expose inner icon buttons inside the outer
      // toolbar control. Keep only the outermost visible frame instead of
      // relying on a fixed size cutoff.
      guard
        !frame.isEmpty,
        frame.width >= minimumToolbarControlDimension,
        frame.height >= minimumToolbarControlDimension
      else {
        continue
      }

      if frames.contains(where: { equivalentFrame($0, frame) }) {
        continue
      }
      if frames.contains(where: { containsFrame($0, frame) }) {
        continue
      }
      frames.removeAll { containsFrame(frame, $0) }
      frames.append(frame)
    }

    return Set(frames.map(frameSignature))
  }

  private func roundedFrame(_ frame: CGRect) -> CGRect {
    CGRect(
      x: frame.minX.rounded(),
      y: frame.minY.rounded(),
      width: frame.width.rounded(),
      height: frame.height.rounded()
    )
  }

  private func frameSignature(_ frame: CGRect) -> String {
    "\(Int(frame.minX)):\(Int(frame.minY)):\(Int(frame.width)):\(Int(frame.height))"
  }

  private func equivalentFrame(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 1) -> Bool {
    abs(lhs.minX - rhs.minX) <= tolerance
      && abs(lhs.minY - rhs.minY) <= tolerance
      && abs(lhs.width - rhs.width) <= tolerance
      && abs(lhs.height - rhs.height) <= tolerance
  }

  private func containsFrame(_ outer: CGRect, _ inner: CGRect, tolerance: CGFloat = 1) -> Bool {
    outer.minX - tolerance <= inner.minX
      && outer.minY - tolerance <= inner.minY
      && outer.maxX + tolerance >= inner.maxX
      && outer.maxY + tolerance >= inner.maxY
  }

  private func createMenuControlDiagnostics(in app: XCUIApplication) -> String {
    let roles: [XCUIElement.ElementType] = [
      .button,
      .menuButton,
      .popUpButton,
      .radioButton,
      .cell,
      .any,
    ]
    var lines: [String] = []

    for role in roles {
      let identifierMatches = mainWindow(in: app)
        .descendants(matching: role)
        .matching(
          NSPredicate(
            format: "identifier == %@ OR identifier == %@",
            Accessibility.sidebarCreateMenuButton,
            Accessibility.sidebarCreateMenuButtonFrame
          )
        )
        .allElementsBoundByIndex
      for (index, element) in identifierMatches.enumerated() {
        lines.append(
          "identifier role=\(role.rawValue) index=\(index) exists=\(element.exists) "
            + "hittable=\(element.isHittable) frame=\(element.frame) label=\(element.label)"
        )
      }

      let titleMatches = mainWindow(in: app)
        .descendants(matching: role)
        .matching(NSPredicate(format: "label == %@", "Create"))
        .allElementsBoundByIndex
      for (index, element) in titleMatches.enumerated() {
        lines.append(
          "title role=\(role.rawValue) index=\(index) exists=\(element.exists) "
            + "hittable=\(element.isHittable) frame=\(element.frame) identifier=\(element.identifier)"
        )
      }
    }

    if lines.isEmpty {
      return "no create menu accessibility candidates"
    }
    return lines.joined(separator: " | ")
  }

  private func createToolbarMenuCandidate(in app: XCUIApplication) -> XCUIElement? {
    for menu in app.menus.allElementsBoundByIndex.prefix(6) {
      let hasNewAgent = presentedMenuItem(
        in: menu,
        identifier: Accessibility.sidebarCreateMenuNewAgentItem
      ).exists
      let hasNewTask = presentedMenuItem(
        in: menu,
        identifier: Accessibility.sidebarCreateMenuNewTaskItem
      ).exists
      let hasNewSession = presentedMenuItem(in: menu, title: "New Session").exists
      if hasNewAgent && hasNewTask && !hasNewSession {
        return menu
      }
    }
    return nil
  }

  private func presentedMenuItem(in menu: XCUIElement, identifier: String) -> XCUIElement {
    let candidateQueries: [XCUIElementQuery] = [
      menu.descendants(matching: .menuItem).matching(identifier: identifier),
      menu.descendants(matching: .button).matching(identifier: identifier),
      menu.descendants(matching: .staticText).matching(identifier: identifier),
      menu.descendants(matching: .any).matching(identifier: identifier),
    ]

    for query in candidateQueries {
      let element = query.firstMatch
      if element.exists {
        return element
      }
    }

    return candidateQueries.last!.firstMatch
  }

  private func presentedMenuItem(in menu: XCUIElement, title: String) -> XCUIElement {
    let predicate = NSPredicate(
      format: "label == %@ OR title == %@ OR identifier == %@",
      title,
      title,
      title
    )

    let candidateQueries: [XCUIElementQuery] = [
      menu.descendants(matching: .menuItem).matching(predicate),
      menu.descendants(matching: .button).matching(predicate),
      menu.descendants(matching: .staticText).matching(predicate),
      menu.descendants(matching: .any).matching(predicate),
    ]

    for query in candidateQueries {
      let element = query.firstMatch
      if element.exists {
        return element
      }
    }

    return candidateQueries.last!.firstMatch
  }

  func testDashboardLandingUsesSingleCreateToolbarAction() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard-landing"]
    )
    let createMenus = app.toolbars.descendants(matching: .any).matching(
      identifier: Accessibility.sidebarCreateMenuButton
    )

    let hasSingleToolbarAction = waitUntil(timeout: Self.actionTimeout) {
      self.distinctVisibleToolbarFrames(for: createMenus).count == 1
    }

    if !hasSingleToolbarAction {
      attachWindowScreenshot(in: app, named: "dashboard-landing-create-toolbar")
      attachAppHierarchy(in: app, named: "dashboard-landing-create-toolbar-hierarchy")
    }

    XCTAssertTrue(
      hasSingleToolbarAction,
      """
      Expected exactly one visible Create toolbar control on dashboard landing.
      diagnostics=\(createMenuControlDiagnostics(in: app))
      """
    )
  }

  func testDashboardCreateMenuOmitsNewSessionAndOpensWorkspaceForNewAgent() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard-landing"]
    )

    openNativeMenuControl(in: app, controlIdentifier: Accessibility.sidebarCreateMenuButton)
    let createMenuAvailable = waitUntil(timeout: Self.fastActionTimeout) {
      self.createToolbarMenuCandidate(in: app) != nil
    }
    XCTAssertTrue(
      createMenuAvailable,
      "Create menu should offer New Agent and New Task without New Session"
    )
    guard let createMenu = createToolbarMenuCandidate(in: app) else {
      return
    }

    let newAgentItem = presentedMenuItem(
      in: createMenu,
      identifier: Accessibility.sidebarCreateMenuNewAgentItem
    )
    let newTaskItem = presentedMenuItem(
      in: createMenu,
      identifier: Accessibility.sidebarCreateMenuNewTaskItem
    )
    let legacyNewSessionItem = presentedMenuItem(in: createMenu, title: "New Session")

    XCTAssertTrue(
      waitForElement(newAgentItem, timeout: Self.fastActionTimeout),
      "Create menu should offer New Agent"
    )
    XCTAssertTrue(
      waitForElement(newTaskItem, timeout: Self.fastActionTimeout),
      "Create menu should offer New Task"
    )
    XCTAssertFalse(
      legacyNewSessionItem.exists,
      "Create menu must not expose New Session"
    )
    XCTAssertFalse(
      newTaskItem.isEnabled,
      "New Task should stay disabled until a writable session is selected"
    )

    newAgentItem.click()

    let workspaceWindow = element(in: app, identifier: Accessibility.workspaceWindow)
    let launchPane = element(in: app, identifier: Accessibility.agentTuiLaunchPane)
    let workspaceState = element(in: app, identifier: Accessibility.agentTuiState)
    let workspaceModelPicker = element(in: app, identifier: Accessibility.workspaceModelPicker)

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        workspaceWindow.exists
          && launchPane.exists
          && workspaceState.label.contains("selection=create")
          && workspaceModelPicker.exists
      },
      """
      Choosing New Agent from the create menu should open the workspace create pane.
      workspaceWindow=\(workspaceWindow.exists)
      launchPane=\(launchPane.exists)
      modelPicker=\(workspaceModelPicker.exists)
      state=\(workspaceState.label)
      """
    )
  }

  func testCockpitCreateMenuOpensNewTaskSheet() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit"]
    )

    openNativeMenuControl(in: app, controlIdentifier: Accessibility.sidebarCreateMenuButton)
    let createMenuAvailable = waitUntil(timeout: Self.fastActionTimeout) {
      self.createToolbarMenuCandidate(in: app) != nil
    }
    XCTAssertTrue(
      createMenuAvailable,
      "Create menu should offer the explicit New Task action in cockpit preview"
    )
    guard let createMenu = createToolbarMenuCandidate(in: app) else {
      return
    }

    let newTaskItem = presentedMenuItem(
      in: createMenu,
      identifier: Accessibility.sidebarCreateMenuNewTaskItem
    )
    XCTAssertTrue(
      waitForElement(newTaskItem, timeout: Self.fastActionTimeout),
      "Create menu should expose New Task in cockpit preview"
    )
    XCTAssertTrue(
      newTaskItem.isEnabled,
      "New Task should be enabled when cockpit preview provides a writable session"
    )
    newTaskItem.click()

    let createTaskSheet = element(in: app, identifier: Accessibility.createTaskSheet)
    XCTAssertTrue(
      createTaskSheet.waitForExistence(timeout: Self.actionTimeout),
      "Choosing New Task from the create menu should open the task sheet"
    )
  }

  func testCockpitUsesSingleWorkspaceToolbarAction() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit"]
    )
    let workspaceButtons = app.toolbars.buttons.matching(
      identifier: Accessibility.workspaceToolbarButton
    )

    let hasSingleToolbarAction = waitUntil(timeout: Self.actionTimeout) {
      self.distinctVisibleToolbarFrames(for: workspaceButtons).count == 1
    }

    if !hasSingleToolbarAction {
      attachWindowScreenshot(in: app, named: "cockpit-workspace-toolbar")
      attachAppHierarchy(in: app, named: "cockpit-workspace-toolbar-hierarchy")
    }

    XCTAssertTrue(
      hasSingleToolbarAction,
      "Expected exactly one visible Workspace toolbar control in cockpit"
    )
  }

  func testCockpitPlacesWorkspaceToolbarActionAfterRefreshGroup() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit"]
    )
    let refreshButton = toolbarButton(in: app, identifier: Accessibility.refreshButton)
    let workspaceButton = toolbarButton(in: app, identifier: Accessibility.workspaceToolbarButton)

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        refreshButton.exists && !refreshButton.frame.isEmpty
          && workspaceButton.exists && !workspaceButton.frame.isEmpty
      },
      "Expected refresh and workspace toolbar buttons to be visible"
    )

    XCTAssertLessThan(
      refreshButton.frame.maxX,
      workspaceButton.frame.minX,
      "Workspace toolbar button should sit after the refresh group"
    )
  }

  func testToolbarUsesNativeConciseWindowTitle() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit"]
    )
    let window = mainWindow(in: app)
    let appChromeState = element(in: app, identifier: Accessibility.appChromeState)
    let toolbarChromeState = element(in: app, identifier: Accessibility.toolbarChromeState)

    XCTAssertTrue(window.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(appChromeState.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(toolbarChromeState.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        toolbarChromeState.label.contains("windowTitle=Cockpit")
      },
      "Expected the preview scenario override to launch directly into cockpit state"
    )

    let toolbar = window.toolbars.firstMatch
    let longToolbarTitle = toolbar.staticTexts[Accessibility.previewSessionTitle]

    XCTAssertTrue(toolbar.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertEqual(
      appChromeState.label,
      "contentChrome=native, interactiveRows=list, controlGlass=native"
    )
    XCTAssertTrue(toolbarChromeState.label.contains("toolbarTitle=native-window"))
    XCTAssertTrue(toolbarChromeState.label.contains("windowTitle=Cockpit"))
    XCTAssertFalse(
      longToolbarTitle.exists,
      "Expected the long session context to stay in detail content, not the toolbar"
    )
  }
}
