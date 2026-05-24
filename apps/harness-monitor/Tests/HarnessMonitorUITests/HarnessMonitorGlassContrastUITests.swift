import AppKit
import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorGlassContrastUITests: HarnessMonitorUITestCase {

  func testSessionTaskCardContentIsReadable() throws {
    let app = launch(mode: "preview")
    let sessionRow = previewSessionTrigger(in: app)

    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    tapPreviewSession(in: app)

    let taskCard = element(in: app, identifier: Accessibility.taskUICard)
    XCTAssertTrue(taskCard.waitForExistence(timeout: Self.actionTimeout))

    let stats = luminanceStats(of: taskCard)
    let screenshot = XCTAttachment(screenshot: taskCard.screenshot())
    screenshot.name = "session-task-card"
    screenshot.lifetime = .keepAlways
    add(screenshot)

    XCTAssertGreaterThan(
      stats.stddev,
      0.04,
      "Section content washed out: stddev=\(stats.stddev), "
        + "min=\(stats.min), max=\(stats.max), "
        + "mean=\(stats.mean), samples=\(stats.count)"
    )
  }

  func testSidebarFilterToolbarButtonIsVisibleAgainstWindowChrome() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard"]
    )

    let filtersButton = sidebarFilterControl(in: app)
    XCTAssertTrue(
      filtersButton.waitForExistence(timeout: Self.actionTimeout),
      "Sidebar filter toolbar control must exist"
    )

    let stats = luminanceStats(of: filtersButton)

    let buttonShot = XCTAttachment(screenshot: filtersButton.screenshot())
    buttonShot.name = "sidebar-filter-toolbar-button"
    buttonShot.lifetime = .keepAlways
    add(buttonShot)

    XCTAssertGreaterThan(
      stats.stddev,
      0.035,
      "Sidebar filter toolbar button content washed out: stddev=\(stats.stddev), "
        + "min=\(stats.min), max=\(stats.max), mean=\(stats.mean), samples=\(stats.count)"
    )
  }

  func testSidebarFilterMenuOptionsAppearWhenToolbarMenuOpens() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard"]
    )

    openSidebarFilters(in: app)
    let sortOption = element(in: app, title: "Recent Activity")
    let focusOption = element(in: app, title: "Open Work")

    XCTAssertTrue(
      sortOption.waitForExistence(timeout: Self.actionTimeout),
      "Sort option must exist"
    )
    XCTAssertTrue(
      focusOption.waitForExistence(timeout: Self.actionTimeout),
      "Focus option must exist"
    )

    let sortShot = XCTAttachment(screenshot: sortOption.screenshot())
    sortShot.name = "sort-option"
    sortShot.lifetime = .keepAlways
    add(sortShot)

    let focusShot = XCTAttachment(screenshot: focusOption.screenshot())
    focusShot.name = "focus-option"
    focusShot.lifetime = .keepAlways
    add(focusShot)

    XCTAssertGreaterThan(
      luminanceStats(of: sortOption).stddev,
      0.025,
      "Sort option should remain readable when the toolbar filter menu opens."
    )
    XCTAssertGreaterThan(
      luminanceStats(of: focusOption).stddev,
      0.025,
      "Focus option should remain readable when the toolbar filter menu opens."
    )
  }

  private func openSidebarFilters(in app: XCUIApplication) {
    let filtersButton = sidebarFilterControl(in: app)

    XCTAssertTrue(filtersButton.waitForExistence(timeout: Self.actionTimeout))
    app.activate()
    if let coordinate = centerCoordinate(in: app, for: filtersButton) {
      coordinate.click()
    } else if filtersButton.isHittable {
      filtersButton.click()
    } else {
      XCTFail("Failed to resolve the actual sidebar filter button")
      return
    }

    let statusOption = element(in: app, title: "Ended")
    XCTAssertTrue(
      statusOption.waitForExistence(timeout: Self.actionTimeout),
      "Sidebar filter menu items should appear once the toolbar filter control opens"
    )
  }

}
