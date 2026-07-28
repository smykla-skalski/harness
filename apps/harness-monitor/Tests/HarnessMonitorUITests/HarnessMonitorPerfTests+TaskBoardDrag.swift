import XCTest

@MainActor
extension HarnessMonitorPerfTests {
  func testTaskBoardDragAndDropHitchRate() {
    guard let app = taskBoardDragApplication() else { return }
    let options = XCTMeasureOptions()
    options.iterationCount = 1
    options.invocationOptions = [.manuallyStart, .manuallyStop]

    measure(
      metrics: [
        XCTHitchMetric(application: app),
        XCTClockMetric(),
      ],
      options: options
    ) {
      launchTaskBoardDragPerformancePreview(app)
      let context = taskBoardDragContext(in: app)
      verifyMeasuredCrossLaneDrop(context, in: app)
      verifySameLaneReorder(context, in: app)
      app.terminate()
    }
  }

  func testTaskBoardContextMenuEdgeMovesAndReveal() {
    guard let app = taskBoardDragApplication() else { return }
    launchTaskBoardDragPerformancePreview(app)
    let context = taskBoardDragContext(in: app)

    verifyContextMenuEdgeMoves(
      context,
      cardID: "perf-drag-todo-01",
      priorBottomID: "perf-drag-todo-24",
      in: app
    )
    app.terminate()
  }

  func testTaskBoardDragAfterRouteRoundTrip() {
    guard let app = taskBoardDragApplication() else { return }
    launchTaskBoardDragPerformancePreview(app)
    let context = taskBoardDragContext(in: app)
    taskBoardCard("perf-drag-todo-01", in: app).click()

    verifyDragAfterRouteRoundTrip(context, in: app)
    app.terminate()
  }

  private func taskBoardDragContext(in app: XCUIApplication) -> TaskBoardDragContext {
    let context = TaskBoardDragContext(
      backlogOrder: taskBoardLaneOrder("inbox", in: app),
      todoOrder: taskBoardLaneOrder("todo", in: app),
      planningOrder: taskBoardLaneOrder("planning", in: app),
      optimisticSettle: element(
        in: app,
        identifier: HarnessMonitorUITestAccessibility.taskBoardOptimisticSettle
      ),
      orchestratorStart: element(
        in: app,
        identifier: "harness.task-board.orchestrator.start"
      )
    )
    ["inbox", "todo", "planning"].forEach {
      XCTAssertTrue(taskBoardLane($0, in: app).waitForExistence(timeout: Self.uiTimeout))
    }
    [
      context.backlogOrder,
      context.todoOrder,
      context.planningOrder,
      context.optimisticSettle,
      context.orchestratorStart,
    ].forEach {
      XCTAssertTrue($0.waitForExistence(timeout: Self.uiTimeout))
    }
    return context
  }

  private func verifyMeasuredCrossLaneDrop(
    _ context: TaskBoardDragContext,
    in app: XCUIApplication
  ) {
    let expectedPlanningOrder = [
      "perf-drag-planning-00",
      "perf-drag-planning-01",
      "perf-drag-todo-01",
      "perf-drag-planning-02",
      "perf-drag-planning-03",
    ]
    startMeasuring()
    dragTaskBoardCard(
      "perf-drag-todo-01",
      after: "perf-drag-planning-01",
      in: app
    )
    stopMeasuring()
    XCTAssertTrue(
      waitForTaskBoardOrder(
        expectedPlanningOrder,
        in: context.planningOrder,
        timeout: Self.actionTimeout
      ),
      "The Planning lane must accept a Todo card"
    )
    let settleText = markerText(context.optimisticSettle)
    let settleMilliseconds = Int(settleText)
    XCTAssertNotNil(
      settleMilliseconds,
      "The drop must publish its optimistic settle duration; got \(settleText)"
    )
    XCTContext.runActivity(
      named: "task-board optimistic settle \(settleText)ms"
    ) { _ in }
    XCTAssertLessThan(
      settleMilliseconds ?? .max,
      1_500,
      "The dropped card must settle optimistically before daemon reconciliation"
    )
    XCTAssertTrue(waitForTaskBoardOrder(
      [
        "perf-drag-backlog-00",
        "perf-drag-backlog-01",
        "perf-drag-backlog-02",
        "perf-drag-backlog-03",
      ],
      in: context.backlogOrder
    ))
    XCTAssertTrue(waitForTaskBoardOrder(
      ["perf-drag-todo-02", "perf-drag-todo-03", "perf-drag-todo-04"],
      in: context.todoOrder
    ))
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { context.orchestratorStart.isEnabled },
      "The cross-lane move must finish before the same-lane move begins"
    )
    XCTAssertTrue(
      waitForTaskBoardOrder(expectedPlanningOrder, in: context.planningOrder),
      "The cross-lane move must remain after async reconciliation"
    )
  }

  private func verifySameLaneReorder(
    _ context: TaskBoardDragContext,
    in app: XCUIApplication
  ) {
    dragTaskBoardCard(
      "perf-drag-todo-02",
      after: "perf-drag-todo-04",
      in: app
    )
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { !context.orchestratorStart.isEnabled },
      "The same-lane move must enter async reconciliation"
    )
    let expectedOrder = [
      "perf-drag-todo-03",
      "perf-drag-todo-04",
      "perf-drag-todo-02",
    ]
    XCTAssertTrue(
      waitForTaskBoardOrder(expectedOrder, in: context.todoOrder),
      "The same-lane move must apply optimistically"
    )
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { context.orchestratorStart.isEnabled },
      "The same-lane move must finish async reconciliation"
    )
    XCTAssertTrue(
      waitForTaskBoardOrder(expectedOrder, in: context.todoOrder),
      "The same-lane move must remain after async reconciliation"
    )
  }

  private func verifyContextMenuEdgeMoves(
    _ context: TaskBoardDragContext,
    cardID: String,
    priorBottomID: String,
    in app: XCUIApplication
  ) {
    let topCard = taskBoardCard(cardID, in: app)
    XCTAssertTrue(
      rightClickElementReliably(in: app, element: topCard),
      "The top Todo card must expose its context menu"
    )
    let moveToTop = app.menuItems["Move to Top"].firstMatch
    let moveToBottom = app.menuItems["Move to Bottom"].firstMatch
    XCTAssertTrue(moveToTop.waitForExistence(timeout: Self.fastActionTimeout))
    XCTAssertTrue(moveToBottom.waitForExistence(timeout: Self.fastActionTimeout))
    XCTAssertFalse(moveToTop.isEnabled, "Move to Top must be disabled at the lane edge")
    XCTAssertTrue(moveToBottom.isEnabled)
    moveToBottom.tap()
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { !context.orchestratorStart.isEnabled },
      "Move to Bottom must enter async reconciliation"
    )
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { context.orchestratorStart.isEnabled },
      "Move to Bottom must finish async reconciliation"
    )
    XCTAssertTrue(
      waitForTaskBoardOrderEnding(
        [priorBottomID, cardID],
        in: context.todoOrder
      ),
      "Move to Bottom must remain after async reconciliation"
    )
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        self.taskBoardCard(cardID, in: app).isHittable
      },
      "The Todo lane must scroll to reveal the card moved to its bottom"
    )
    let bottomCard = taskBoardCard(cardID, in: app)
    XCTAssertTrue(rightClickElementReliably(in: app, element: bottomCard))
    XCTAssertTrue(moveToTop.waitForExistence(timeout: Self.fastActionTimeout))
    XCTAssertTrue(moveToBottom.waitForExistence(timeout: Self.fastActionTimeout))
    XCTAssertTrue(moveToTop.isEnabled)
    XCTAssertFalse(
      moveToBottom.isEnabled,
      "Move to Bottom must be disabled at the lane edge"
    )
    app.typeKey(.escape, modifierFlags: [])
  }

  private func verifyDragAfterRouteRoundTrip(
    _ context: TaskBoardDragContext,
    in app: XCUIApplication
  ) {
    let policiesRoute = element(
      in: app,
      identifier: "harness.dashboard.route.policycanvas"
    )
    XCTAssertTrue(policiesRoute.waitForExistence(timeout: Self.fastActionTimeout))
    policiesRoute.click()
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        !self.taskBoardCard("perf-drag-planning-00", in: app).exists
      },
      "The board must leave the hierarchy after switching routes"
    )
    let boardRoute = element(
      in: app,
      identifier: "harness.dashboard.route.taskboard"
    )
    XCTAssertTrue(boardRoute.waitForExistence(timeout: Self.fastActionTimeout))
    boardRoute.click()
    XCTAssertTrue(
      taskBoardCard("perf-drag-planning-00", in: app)
        .waitForExistence(timeout: Self.actionTimeout)
    )
    dragTaskBoardCard(
      "perf-drag-planning-00",
      after: "perf-drag-planning-01",
      in: app
    )
    XCTAssertTrue(
      waitForTaskBoardOrder(
        [
          "perf-drag-planning-01",
          "perf-drag-planning-00",
        ],
        in: context.planningOrder
      ),
      "Drag and drop must remain active after switching away from the board and back"
    )
  }

  private func taskBoardDragApplication() -> XCUIApplication? {
    let productRoots = ProcessInfo.processInfo.environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"]
      .map { $0.split(separator: ":").map(String.init) }
      ?? []
    for root in productRoots {
      let appURL = URL(fileURLWithPath: root, isDirectory: true)
        .appendingPathComponent("Harness Monitor UI Testing.app", isDirectory: true)
      if FileManager.default.fileExists(atPath: appURL.path) {
        return XCUIApplication(url: appURL)
      }
    }
    XCTFail("The lane's built UI-test host is unavailable in \(productRoots)")
    return nil
  }

  private func launchTaskBoardDragPerformancePreview(_ app: XCUIApplication) {
    terminateIfRunning(app)
    app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
    app.launchEnvironment = [
      "HARNESS_MONITOR_UI_TESTS": "1",
      "HARNESS_MONITOR_KEEP_ANIMATIONS": "1",
      "HARNESS_MONITOR_TEST_ACTION_DELAY_MS": "250",
      Self.launchModeKey: "preview",
      "HARNESS_MONITOR_PREVIEW_SCENARIO": "task-board-drag-performance",
    ]
    guard configureIsolatedDataHome(for: app, purpose: "task-board-drag-performance") != nil else {
      return
    }
    app.launch()

    let boardRoot = element(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.sessionsBoardRoot
    )
    XCTAssertTrue(boardRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(
      taskBoardCard("perf-drag-todo-01", in: app)
        .waitForExistence(timeout: Self.uiTimeout)
    )
  }

  private func dragTaskBoardCard(
    _ itemID: String,
    before targetID: String,
    in app: XCUIApplication
  ) {
    dragTaskBoardCard(
      itemID,
      to: taskBoardCard(targetID, in: app),
      normalizedOffset: CGVector(dx: 0.5, dy: 0.2),
      in: app
    )
  }

  private func dragTaskBoardCard(
    _ itemID: String,
    after targetID: String,
    in app: XCUIApplication
  ) {
    dragTaskBoardCard(
      itemID,
      to: taskBoardCard(targetID, in: app),
      normalizedOffset: CGVector(dx: 0.5, dy: 0.8),
      in: app
    )
  }

  private func dragTaskBoardCard(
    _ itemID: String,
    toEmptyLane lane: XCUIElement,
    in app: XCUIApplication
  ) {
    dragTaskBoardCard(
      itemID,
      to: lane,
      normalizedOffset: CGVector(dx: 0.5, dy: 0.5),
      in: app
    )
  }

  private func dragTaskBoardCard(
    _ itemID: String,
    afterLast targetID: String,
    in lane: XCUIElement,
    app: XCUIApplication
  ) {
    let target = taskBoardCard(targetID, in: app)
    XCTAssertTrue(waitForElement(target, timeout: Self.actionTimeout))
    XCTAssertTrue(waitForElement(lane, timeout: Self.actionTimeout))
    let dropY = min(target.frame.maxY + 24, lane.frame.maxY - 24)
    XCTAssertGreaterThan(dropY, target.frame.maxY)
    XCTContext.runActivity(
      named:
        "task-board-drag frames window=\(app.windows.firstMatch.frame) lane=\(lane.frame) target=\(target.frame) endpoint=(\(lane.frame.midX), \(dropY))"
    ) { _ in }
    let normalizedY = (dropY - lane.frame.minY) / lane.frame.height
    dragTaskBoardCard(
      itemID,
      to: lane,
      normalizedOffset: CGVector(dx: 0.5, dy: normalizedY),
      in: app
    )
  }

  private func dragTaskBoardCard(
    _ itemID: String,
    to target: XCUIElement,
    normalizedOffset: CGVector,
    in app: XCUIApplication
  ) {
    let source = taskBoardCard(itemID, in: app)
    XCTAssertTrue(waitForElement(source, timeout: Self.actionTimeout))
    XCTAssertTrue(waitForElement(target, timeout: Self.actionTimeout))
    let start = source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    let end = target.coordinate(withNormalizedOffset: normalizedOffset)
    start.click(
      forDuration: 0.5,
      thenDragTo: end,
      withVelocity: .fast,
      thenHoldForDuration: 0.25
    )
  }

  private func waitForTaskBoardOrder(
    _ itemIDs: [String],
    in orderMarker: XCUIElement,
    timeout: TimeInterval = HarnessMonitorPerfTests.actionTimeout
  ) -> Bool {
    return waitUntil(timeout: timeout, pollInterval: Self.fastPollInterval) {
      self.markerText(orderMarker)
        .split(separator: ",")
        .map(String.init)
        .starts(with: itemIDs)
    }
  }

  private func waitForTaskBoardOrderEnding(
    _ itemIDs: [String],
    in orderMarker: XCUIElement,
    timeout: TimeInterval = HarnessMonitorPerfTests.actionTimeout
  ) -> Bool {
    waitUntil(timeout: timeout, pollInterval: Self.fastPollInterval) {
      self.markerText(orderMarker)
        .split(separator: ",")
        .map(String.init)
        .suffix(itemIDs.count)
        .elementsEqual(itemIDs)
    }
  }

  private func taskBoardCard(_ itemID: String, in app: XCUIApplication) -> XCUIElement {
    app.buttons
      .matching(identifier: "harness.task-board.api-item.\(itemID)")
      .firstMatch
  }

  private func taskBoardLane(_ lane: String, in app: XCUIApplication) -> XCUIElement {
    element(in: app, identifier: "harness.task-board.column.\(lane)")
  }

  private func taskBoardLaneOrder(_ lane: String, in app: XCUIApplication) -> XCUIElement {
    element(in: app, identifier: "harness.task-board.column.\(lane).order")
  }
}

@MainActor
private struct TaskBoardDragContext {
  let backlogOrder: XCUIElement
  let todoOrder: XCUIElement
  let planningOrder: XCUIElement
  let optimisticSettle: XCUIElement
  let orchestratorStart: XCUIElement
}
