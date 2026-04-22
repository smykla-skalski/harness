import AppKit
import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorGlassContrastUITests: HarnessMonitorUITestCase {

  func testToolbarCenterpieceContentIsReadable() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard"]
    )

    let centerpiece = element(in: app, identifier: Accessibility.toolbarCenterpiece)
    XCTAssertTrue(centerpiece.waitForExistence(timeout: Self.actionTimeout))

    let stats = luminanceStats(of: centerpiece)
    let screenshot = XCTAttachment(screenshot: centerpiece.screenshot())
    screenshot.name = "toolbar-centerpiece"
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

  func testInspectorEmptyStateIsReadable() throws {
    let app = launch(mode: "empty")

    let emptyState = element(in: app, identifier: Accessibility.inspectorEmptyState)
    XCTAssertTrue(emptyState.waitForExistence(timeout: Self.actionTimeout))

    let stats = luminanceStats(of: emptyState)
    let screenshot = XCTAttachment(screenshot: emptyState.screenshot())
    screenshot.name = "inspector-empty-state"
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

  func testSidebarStatusPickerBackgroundIsVisible() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard"]
    )

    activateSidebarSearch(in: app)
    let statusPicker = element(
      in: app,
      identifier: Accessibility.sidebarStatusPicker
    )
    let filtersCard = element(
      in: app,
      identifier: Accessibility.sidebarFiltersCard
    )
    XCTAssertTrue(
      statusPicker.waitForExistence(timeout: Self.actionTimeout),
      "Status picker must exist"
    )
    XCTAssertTrue(filtersCard.exists, "Filters card must exist")

    let pickerEdge = edgeLuminance(of: statusPicker, region: .top)
    let cardBg = edgeLuminance(of: filtersCard, region: .top)

    let pickerShot = XCTAttachment(screenshot: statusPicker.screenshot())
    pickerShot.name = "status-picker"
    pickerShot.lifetime = .keepAlways
    add(pickerShot)

    let cardShot = XCTAttachment(screenshot: filtersCard.screenshot())
    cardShot.name = "filter-card-background"
    cardShot.lifetime = .keepAlways
    add(cardShot)

    let delta = abs(pickerEdge - cardBg)
    print("SELECT_CONTRAST pickerEdge=\(pickerEdge) cardBg=\(cardBg) delta=\(delta)")

    // Native menu pickers in a sidebar use subtler chrome than the old
    // segmented control. The important contract is that the picker stays
    // visibly brighter than a washed-out vibrancy surface and still reads
    // as distinct from the surrounding filter card.
    XCTAssertGreaterThan(
      pickerEdge,
      0.2,
      "Status picker should remain bright enough to read as an interactive control: "
        + "pickerEdge=\(pickerEdge)."
    )
    XCTAssertGreaterThan(
      delta,
      0.025,
      "Status picker has no visible contrast against sidebar: "
        + "pickerEdge=\(pickerEdge), cardBg=\(cardBg), delta=\(delta)."
    )
  }

  func testSidebarSecondarySegmentsShareConsistentBackground() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard"]
    )

    activateSidebarSearch(in: app)
    let sortPicker = element(
      in: app,
      identifier: Accessibility.sidebarSortPicker
    )
    let focusPicker = element(in: app, identifier: Accessibility.sidebarFocusPicker)

    XCTAssertTrue(
      sortPicker.waitForExistence(timeout: Self.actionTimeout),
      "Sort picker must exist"
    )
    XCTAssertTrue(
      focusPicker.waitForExistence(timeout: Self.actionTimeout),
      "Focus picker must exist"
    )

    let sortColor = averageColor(of: sortPicker)
    let focusColor = averageColor(of: focusPicker)

    let sortShot = XCTAttachment(screenshot: sortPicker.screenshot())
    sortShot.name = "sort-picker"
    sortShot.lifetime = .keepAlways
    add(sortShot)

    let focusShot = XCTAttachment(screenshot: focusPicker.screenshot())
    focusShot.name = "focus-picker"
    focusShot.lifetime = .keepAlways
    add(focusShot)

    print(
      "SEGMENT_RGB sort=(\(sortColor.red),\(sortColor.green),\(sortColor.blue)) "
        + "focus=(\(focusColor.red),\(focusColor.green),\(focusColor.blue))"
    )

    let maxDelta = max(
      abs(sortColor.red - focusColor.red),
      abs(sortColor.green - focusColor.green),
      abs(sortColor.blue - focusColor.blue)
    )

    XCTAssertLessThan(
      maxDelta,
      0.06,
      "Sidebar filter pickers do not share a consistent background tone: "
        + "sort=(\(sortColor.red),\(sortColor.green),\(sortColor.blue)), "
        + "focus=(\(focusColor.red),\(focusColor.green),\(focusColor.blue)), "
        + "maxChannelDelta=\(maxDelta)."
    )
  }

  private func activateSidebarSearch(in app: XCUIApplication) {
    let searchField = editableField(in: app, identifier: Accessibility.sidebarSearchField)
    let filtersCard = element(in: app, identifier: Accessibility.sidebarFiltersCard)

    XCTAssertTrue(searchField.waitForExistence(timeout: Self.actionTimeout))
    tapElement(in: app, identifier: Accessibility.sidebarSearchField)
    XCTAssertTrue(
      filtersCard.waitForExistence(timeout: Self.actionTimeout),
      "Sidebar filters should appear once the native search field becomes active"
    )
  }

}
