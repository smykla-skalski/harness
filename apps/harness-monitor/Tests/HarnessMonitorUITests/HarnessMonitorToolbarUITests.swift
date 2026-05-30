import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

final class HarnessMonitorToolbarUITests: HarnessMonitorUITestCase {
  let minimumToolbarControlDimension: CGFloat = 24

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

  func testDashboardWindowPlacesQuickActionsInToolbarChrome() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard"]
    )
    let dashboardWindow = element(in: app, identifier: Accessibility.dashboardWindowRoot)
    let toolbar = mainWindow(in: app).toolbars.firstMatch
    let newSessionButton = button(in: app, identifier: Accessibility.dashboardNewSessionButton)
    let openFolderButton = button(in: app, identifier: Accessibility.dashboardOpenFolderButton)
    let sleepPreventionButton = button(in: app, identifier: Accessibility.sleepPreventionButton)

    XCTAssertTrue(waitForElement(dashboardWindow, timeout: Self.actionTimeout))
    XCTAssertTrue(waitForElement(toolbar, timeout: Self.actionTimeout))
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        newSessionButton.exists && !newSessionButton.frame.isEmpty
          && openFolderButton.exists && !openFolderButton.frame.isEmpty
          && sleepPreventionButton.exists && !sleepPreventionButton.frame.isEmpty
      },
      "Expected dashboard toolbar quick actions and sleep prevention to be visible"
    )

    for button in [newSessionButton, openFolderButton, sleepPreventionButton] {
      XCTAssertGreaterThanOrEqual(button.frame.minY, toolbar.frame.minY - 4)
      XCTAssertLessThanOrEqual(button.frame.maxY, toolbar.frame.maxY + 4)
    }

    for button in [newSessionButton, openFolderButton] {
      XCTAssertGreaterThan(
        button.frame.midX,
        toolbar.frame.midX,
        "Dashboard quick actions should sit on the trailing side of the toolbar"
      )
      XCTAssertLessThan(
        button.frame.maxX,
        sleepPreventionButton.frame.minX,
        "Dashboard quick actions should remain grouped before the trailing sleep control"
      )
    }
  }

  func testPolicyRouteDoesNotRetainReviewsToolbarSearch() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard"]
    )
    let dashboardWindow = element(in: app, identifier: Accessibility.dashboardWindowRoot)
    let reviewsRoute = element(
      in: app,
      identifier: Accessibility.dashboardWindowRoute("reviews")
    )
    let policyRoute = element(
      in: app,
      identifier: Accessibility.dashboardWindowRoute("policyCanvas")
    )
    let policyRoot = element(in: app, identifier: Accessibility.policyCanvasRoot)
    let reviewsSearchField = app.searchFields["Search repos, titles, authors, or labels"].firstMatch

    XCTAssertTrue(waitForElement(dashboardWindow, timeout: Self.actionTimeout))
    XCTAssertTrue(waitForElement(reviewsRoute, timeout: Self.actionTimeout))
    XCTAssertTrue(waitForElement(policyRoute, timeout: Self.actionTimeout))
    XCTAssertTrue(
      tapElementReliably(in: app, element: reviewsRoute),
      "Reviews route should be selectable from the dashboard sidebar"
    )
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        reviewsSearchField.exists && !reviewsSearchField.frame.isEmpty
      },
      "Reviews toolbar search should appear when the reviews route is active"
    )

    XCTAssertTrue(
      tapElementReliably(in: app, element: policyRoute),
      "Policies route should be selectable from the dashboard sidebar"
    )
    XCTAssertTrue(waitForElement(policyRoot, timeout: Self.actionTimeout))

    let reviewsSearchDismissed = waitUntil(timeout: Self.actionTimeout) {
      !reviewsSearchField.exists || reviewsSearchField.frame.isEmpty
    }

    if !reviewsSearchDismissed {
      attachWindowScreenshot(in: app, named: "policy-route-retained-reviews-search")
      attachAppHierarchy(in: app, named: "policy-route-retained-reviews-search-hierarchy")
    }

    XCTAssertTrue(
      reviewsSearchDismissed,
      "Reviews toolbar search must not remain visible after switching to Policies"
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

  func testCockpitPlacesCreateMenuBeforeRefreshGroup() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit"]
    )
    let createButton = button(in: app, identifier: Accessibility.sidebarCreateMenuButton)
    let refreshButton = toolbarButton(in: app, identifier: Accessibility.refreshButton)

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        createButton.exists && !createButton.frame.isEmpty
          && refreshButton.exists && !refreshButton.frame.isEmpty
      },
      "Expected create and refresh toolbar controls to be visible"
    )

    let gap = refreshButton.frame.minX - createButton.frame.maxX
    XCTAssertLessThan(
      createButton.frame.maxX,
      refreshButton.frame.minX,
      "Create menu should sit before the refresh group"
    )
    XCTAssertGreaterThan(
      gap,
      4,
      "Create menu should be separated from the refresh group by toolbar spacing"
    )
  }

  func testCockpitUsesSingleWorkspaceToolbarAction() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit"]
    )
    let workspaceButtons = app.toolbars.buttons.matching(
      identifier: Accessibility.sessionAttentionToolbarButton
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
    let workspaceButton = toolbarButton(
      in: app, identifier: Accessibility.sessionAttentionToolbarButton)

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
