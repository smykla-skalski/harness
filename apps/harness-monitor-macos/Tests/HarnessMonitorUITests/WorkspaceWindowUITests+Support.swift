import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
protocol WorkspaceWindowUITestSupporting: AnyObject {}

@MainActor
extension WorkspaceWindowUITestSupporting where Self: HarnessMonitorUITestCase {
  func launchInCockpitPreview(
    additionalEnvironment: [String: String] = [:]
  ) -> XCUIApplication {
    var environment = [
      "HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit"
    ]
    environment.merge(additionalEnvironment) { _, new in new }
    return launch(
      mode: "preview",
      additionalEnvironment: environment
    )
  }

  func openWorkspaceWindow(in app: XCUIApplication) {
    tapDockButton(in: app, identifier: Accessibility.workspaceToolbarButton, label: "workspace")
    XCTAssertTrue(
      waitForElement(
        element(in: app, identifier: Accessibility.agentTuiLaunchPane),
        timeout: Self.actionTimeout
      )
    )
  }

  func reopenWorkspaceWindow(in app: XCUIApplication) {
    tapDockButton(in: app, identifier: Accessibility.workspaceToolbarButton, label: "workspace")
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        self.element(in: app, identifier: Accessibility.agentTuiLaunchPane).exists
          || self.element(in: app, identifier: Accessibility.agentTuiSessionPane).exists
      }
    )
  }

  func closeWorkspaceWindow(in app: XCUIApplication) {
    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        !self.element(in: app, identifier: Accessibility.agentTuiLaunchPane).exists
          && !self.element(in: app, identifier: Accessibility.agentTuiSessionPane).exists
      }
    )
  }

  func startAgentTui(
    in app: XCUIApplication,
    runtimeTitle: String,
    prompt: String
  ) {
    let launchPane = element(in: app, identifier: Accessibility.agentTuiLaunchPane)
    if !waitForElement(launchPane, timeout: Self.fastPollInterval) {
      tapButton(in: app, identifier: Accessibility.agentTuiCreateTab)
      let state = element(in: app, identifier: Accessibility.agentTuiState)
      XCTAssertTrue(
        waitUntil(timeout: Self.actionTimeout) {
          launchPane.exists || state.label.contains("selection=create")
        }
      )
    }

    _ = runtimeTitle
    _ = prompt
    app.activate()
    app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

    let state = element(in: app, identifier: Accessibility.agentTuiState)
    let sessionPane = element(in: app, identifier: Accessibility.agentTuiSessionPane)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        let stateLabel = state.label
        return
          sessionPane.exists
          || stateLabel.contains("startTui=1:")
          || stateLabel.contains("codexStart=1:")
          || stateLabel.contains("toast=failure:")
      },
      """
      Starting the agent pane did not make progress after the launch action fired.
      state=\(state.label)
      """
    )

    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) {
        sessionPane.exists
      }
    )
  }

  func revealWorkspaceLaunchAction(in app: XCUIApplication, identifier: String) {
    let maxRevealAttempts = 2
    let revealDragDistanceRatio: CGFloat = 0.4
    let launchPane = element(in: app, identifier: Accessibility.agentTuiLaunchPane)
    XCTAssertTrue(waitForElement(launchPane, timeout: Self.actionTimeout))
    var launchAction = descendantButton(in: launchPane, identifier: identifier)
    XCTAssertTrue(waitForElement(launchAction, timeout: Self.actionTimeout))

    let scrollTarget = workspaceLaunchScrollTarget(in: app, launchPane: launchPane)
    var previousRevealSignature: String?
    recordWorkspaceLaunchTrace(
      in: app,
      event: "reveal.begin",
      context: WorkspaceLaunchTraceContext(
        launchPane: launchPane,
        scrollTarget: scrollTarget,
        launchAction: launchAction,
        identifier: identifier
      ),
      extraDetails: ["attempt": "initial"]
    )

    for attempt in 0..<maxRevealAttempts {
      launchAction = descendantButton(in: launchPane, identifier: identifier)
      if launchActionIsVisible(
        in: app,
        launchPane: launchPane,
        scrollTarget: scrollTarget,
        launchAction: launchAction,
        identifier: identifier
      ) {
        recordWorkspaceLaunchTrace(
          in: app,
          event: "reveal.visible",
          context: WorkspaceLaunchTraceContext(
            launchPane: launchPane,
            scrollTarget: scrollTarget,
            launchAction: launchAction,
            identifier: identifier
          ),
          extraDetails: ["attempt": String(attempt)]
        )
        return
      }

      let revealSignature = workspaceLaunchRevealSignature(
        in: app,
        launchPane: launchPane,
        scrollTarget: scrollTarget,
        identifier: identifier
      )
      if let previousRevealSignature, previousRevealSignature == revealSignature {
        recordWorkspaceLaunchTrace(
          in: app,
          event: "reveal.stalled",
          context: WorkspaceLaunchTraceContext(
            launchPane: launchPane,
            scrollTarget: scrollTarget,
            launchAction: launchAction,
            identifier: identifier
          ),
          extraDetails: ["attempt": String(attempt)]
        )
        break
      }
      previousRevealSignature = revealSignature

      recordWorkspaceLaunchTrace(
        in: app,
        event: "reveal.scroll",
        context: WorkspaceLaunchTraceContext(
          launchPane: launchPane,
          scrollTarget: scrollTarget,
          launchAction: launchAction,
          identifier: identifier
        ),
        extraDetails: ["attempt": String(attempt)]
      )
      dragUp(in: app, element: scrollTarget, distanceRatio: revealDragDistanceRatio)
      RunLoop.current.run(until: Date.now.addingTimeInterval(Self.fastPollInterval))
    }

    recordWorkspaceLaunchTrace(
      in: app,
      event: "reveal.failed",
      context: WorkspaceLaunchTraceContext(
        launchPane: launchPane,
        scrollTarget: scrollTarget,
        launchAction: launchAction,
        identifier: identifier
      ),
      extraDetails: ["attempt": "failed"]
    )
    XCTFail("Failed to reveal launch action \(identifier)")
  }

  private func launchActionIsVisible(
    in app: XCUIApplication,
    launchPane: XCUIElement,
    scrollTarget: XCUIElement,
    launchAction: XCUIElement,
    identifier: String
  ) -> Bool {
    if launchAction.exists && launchAction.isHittable {
      return true
    }

    let frameMarker = descendantFrameElement(in: launchPane, identifier: "\(identifier).frame")
    guard frameMarker.exists, !frameMarker.frame.isEmpty else {
      return false
    }

    let containingWindow = window(in: app, containing: frameMarker)
    let viewportFrame = scrollTarget.frame.intersection(containingWindow.frame)
    guard !viewportFrame.isNull, !viewportFrame.isEmpty else {
      return false
    }

    let visibleFrame = viewportFrame.intersection(frameMarker.frame)
    guard !visibleFrame.isNull, !visibleFrame.isEmpty else {
      return false
    }

    let minimumVisibleHeight = min(24, max(frameMarker.frame.height / 2, 1))
    return visibleFrame.height >= minimumVisibleHeight
  }

  private func workspaceLaunchScrollTarget(
    in app: XCUIApplication,
    launchPane: XCUIElement
  ) -> XCUIElement {
    let launchWindow = window(in: app, containing: launchPane)
    let nestedScrollViews = launchPane.descendants(matching: .scrollView)

    if let scrollView = visibleLargestScrollTarget(in: nestedScrollViews, window: launchWindow) {
      return scrollView
    }

    if launchPane.exists, !launchPane.frame.isEmpty, launchPane.elementType == .scrollView {
      return launchPane
    }

    if let scrollView = overlappingDetailScrollTarget(
      in: launchWindow.descendants(matching: .scrollView),
      window: launchWindow,
      container: launchPane
    ) {
      return scrollView
    }

    if let scrollView = overlappingDetailScrollTarget(
      in: app.descendants(matching: .scrollView),
      window: launchWindow,
      container: launchPane
    ) {
      return scrollView
    }
    if let largest = visibleLargestScrollTarget(
      in: launchWindow.descendants(matching: .scrollView),
      window: launchWindow
    ) {
      return largest
    }
    if let largest = visibleLargestScrollTarget(
      in: app.descendants(matching: .scrollView),
      window: launchWindow
    ) {
      return largest
    }
    return launchPane
  }

  private func largestScrollTarget(in query: XCUIElementQuery) -> XCUIElement? {
    let searchCount = min(query.count, 12)
    var bestArea: CGFloat = 0
    var bestMatch: XCUIElement?
    for index in 0..<searchCount {
      let candidate = query.element(boundBy: index)
      guard candidate.exists, !candidate.frame.isEmpty else { continue }
      let area = candidate.frame.width * candidate.frame.height
      if area > bestArea {
        bestArea = area
        bestMatch = candidate
      }
    }
    return bestMatch
  }

  private func visibleLargestScrollTarget(
    in query: XCUIElementQuery,
    window: XCUIElement
  ) -> XCUIElement? {
    guard window.exists, !window.frame.isEmpty else {
      return nil
    }

    let windowFrame = window.frame
    let searchCount = min(query.count, 12)
    var bestArea: CGFloat = 0
    var bestMatch: XCUIElement?

    for index in 0..<searchCount {
      let candidate = query.element(boundBy: index)
      guard candidate.exists, !candidate.frame.isEmpty else { continue }

      let visibleFrame = candidate.frame.intersection(windowFrame)
      guard !visibleFrame.isNull, !visibleFrame.isEmpty else { continue }

      let area = visibleFrame.width * visibleFrame.height
      if area > bestArea {
        bestArea = area
        bestMatch = candidate
      }
    }

    return bestMatch
  }

  private func overlappingDetailScrollTarget(
    in query: XCUIElementQuery,
    window: XCUIElement,
    container: XCUIElement
  ) -> XCUIElement? {
    guard container.exists, !container.frame.isEmpty else { return nil }

    let containerFrame = container.frame
    let containerMidX = containerFrame.midX
    let windowMidX = window.frame.midX
    let candidates = query.allElementsBoundByIndex.filter { candidate in
      guard candidate.exists, !candidate.frame.isEmpty else { return false }
      let candidateFrame = candidate.frame
      let visibleFrame = candidateFrame.intersection(window.frame)
      let overlapsContainerHorizontally =
        candidateFrame.minX <= containerFrame.maxX
        && containerFrame.minX <= candidateFrame.maxX
      let overlapsContainerVertically =
        candidateFrame.minY <= containerFrame.maxY
        && containerFrame.minY <= candidateFrame.maxY
      return
        candidateFrame.minX <= containerMidX
        && containerMidX <= candidateFrame.maxX
        && overlapsContainerHorizontally
        && overlapsContainerVertically
        && !visibleFrame.isNull
        && !visibleFrame.isEmpty
    }

    let detailCandidates = candidates.filter { candidate in
      candidate.frame.midX > windowMidX
    }

    let preferredCandidates = detailCandidates.isEmpty ? candidates : detailCandidates
    return preferredCandidates.max { left, right in
      left.frame.width * left.frame.height < right.frame.width * right.frame.height
    }
  }

}
