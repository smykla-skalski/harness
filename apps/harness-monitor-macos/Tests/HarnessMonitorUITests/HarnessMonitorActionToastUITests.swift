import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorActionToastUITests: HarnessMonitorUITestCase {
  private static let toastDismissOverrideKey = "HARNESS_MONITOR_TEST_TOAST_DISMISS_MS"
  private static let toastSeedKey = "HARNESS_MONITOR_TEST_SEED_TOASTS"
  private static let longDismissMilliseconds = 10_000

  func testActionToastAppearsAndAutoDismisses() throws {
    let app = launch(mode: "preview")

    tapPreviewSession(in: app)

    let observeButton = app.buttons["Observe"].firstMatch
    XCTAssertTrue(observeButton.waitForExistence(timeout: Self.actionTimeout))
    if observeButton.isHittable {
      observeButton.tap()
    } else if let coordinate = centerCoordinate(in: app, for: observeButton) {
      coordinate.tap()
    } else {
      XCTFail("Failed to tap Observe button")
    }

    let toast = element(in: app, identifier: Accessibility.actionToast)
    XCTAssertTrue(
      toast.waitForExistence(timeout: Self.actionTimeout),
      "Toast should appear after action"
    )

    let dismissed = waitUntil(timeout: 2) { !toast.exists }
    XCTAssertTrue(dismissed, "Toast should dismiss after appearing")
  }

  func testStackedToastsAreVisible() throws {
    let app = launchWithSeededToasts(["Observe session", "Create task"])

    let toastRows = toastRowQuery(in: app)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { toastRows.count == 2 },
      "Expected exactly 2 stacked toast rows but found \(toastRows.count)"
    )
  }

  func testOldestToastEvicted() throws {
    let app = launchWithSeededToasts([
      "Observe session",
      "Create task",
      "Save checkpoint",
      "Change role",
    ])

    let toastRows = toastRowQuery(in: app)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { toastRows.count == 3 },
      "Expected maxVisible=3 to evict the oldest toast but found \(toastRows.count) rows"
    )
  }

  func testCloseButtonPromotesNext() throws {
    let app = launchWithSeededToasts(["Observe session", "Create task"])

    let toastRows = toastRowQuery(in: app)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { toastRows.count == 2 }
    )

    let closeButtons = app.descendants(matching: .button)
      .matching(identifier: Accessibility.actionToastCloseButton)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { closeButtons.count == 2 },
      "Should find 2 close buttons (one per visible toast)"
    )

    let topClose = closeButtons.element(boundBy: 0)
    XCTAssertTrue(topClose.exists)
    if topClose.isHittable {
      topClose.click()
    } else if let coordinate = centerCoordinate(in: app, for: topClose) {
      coordinate.click()
    } else {
      XCTFail("Cannot click close button")
    }

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { toastRows.count == 1 },
      "After closing the top toast there should be exactly 1 row remaining"
    )
  }

  func testEscDismissesToast() throws {
    let app = launchWithSeededToasts(["Observe session", "Create task"])

    let toastRows = toastRowQuery(in: app)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { toastRows.count == 2 }
    )

    app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { toastRows.count == 1 },
      "Esc keyboard shortcut should dismiss one toast via cancelAction binding"
    )
  }

  func testIdenticalMessageDedupes() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: [
        "HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit",
        Self.toastDismissOverrideKey: String(Self.longDismissMilliseconds),
      ]
    )

    let createButton = button(in: app, identifier: Accessibility.createTaskButton)
    XCTAssertTrue(createButton.waitForExistence(timeout: Self.actionTimeout))

    fillCreateTaskTitle(in: app, text: "First dedupe task")
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { createButton.isEnabled }
    )
    tapViaCoordinate(in: app, element: createButton)

    let toastRows = toastRowQuery(in: app)
    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) { toastRows.count == 1 },
      "First Create Task action should produce exactly 1 toast"
    )

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { !createButton.isEnabled },
      "Create Task should re-disable after the first action clears the title"
    )

    fillCreateTaskTitle(in: app, text: "Second dedupe task")
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { createButton.isEnabled }
    )
    tapViaCoordinate(in: app, element: createButton)

    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) { toastRows.count == 1 },
      "Second Create Task action with the same message should dedupe (still 1 toast)"
    )
  }
}

extension HarnessMonitorActionToastUITests {
  fileprivate func launchWithSeededToasts(_ messages: [String]) -> XCUIApplication {
    launch(
      mode: "preview",
      additionalEnvironment: [
        "HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit",
        Self.toastDismissOverrideKey: String(Self.longDismissMilliseconds),
        Self.toastSeedKey: messages.joined(separator: ","),
      ]
    )
  }

  fileprivate func toastRowQuery(in app: XCUIApplication) -> XCUIElementQuery {
    app.descendants(matching: .button)
      .matching(identifier: Accessibility.actionToastCloseButton)
  }

  fileprivate func fillCreateTaskTitle(in app: XCUIApplication, text: String) {
    let titleField = editableField(in: app, identifier: Accessibility.createTaskTitleField)
    XCTAssertTrue(titleField.waitForExistence(timeout: Self.actionTimeout))
    if titleField.isHittable {
      titleField.tap()
    } else if let coordinate = centerCoordinate(in: app, for: titleField) {
      coordinate.tap()
    }
    titleField.typeKey("a", modifierFlags: .command)
    titleField.typeText(text)
  }

  fileprivate func tapViaCoordinate(in app: XCUIApplication, element: XCUIElement) {
    if element.isHittable {
      element.tap()
      return
    }
    guard let coordinate = centerCoordinate(in: app, for: element) else {
      XCTFail("Cannot resolve coordinate for \(element)")
      return
    }
    coordinate.tap()
  }
}
