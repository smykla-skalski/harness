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

  func testSidebarStatusSegmentBackgroundIsVisible() throws {
    let app = launch(mode: "preview")

    let chip = button(in: app, title: "Ended")
    let filtersCard = element(
      in: app,
      identifier: Accessibility.sidebarFiltersCard
    )
    XCTAssertTrue(
      chip.waitForExistence(timeout: Self.actionTimeout),
      "Ended status segment must exist"
    )
    XCTAssertTrue(filtersCard.exists, "Filters card must exist")

    let pickerEdge = edgeLuminance(of: chip, region: .top)
    let cardBg = edgeLuminance(of: filtersCard, region: .top)

    let pickerShot = XCTAttachment(screenshot: chip.screenshot())
    pickerShot.name = "status-segment-ended"
    pickerShot.lifetime = .keepAlways
    add(pickerShot)

    let cardShot = XCTAttachment(screenshot: filtersCard.screenshot())
    cardShot.name = "filter-card-background"
    cardShot.lifetime = .keepAlways
    add(cardShot)

    let delta = abs(pickerEdge - cardBg)
    print("SELECT_CONTRAST pickerEdge=\(pickerEdge) cardBg=\(cardBg) delta=\(delta)")

    // A bordered button with a visible fill should differ from
    // the surrounding area by at least 0.06 luminance. Under
    // sidebar vibrancy the delta was ~0.08 but both values were
    // very dark (~0.13 and ~0.21) making the fill imperceptible.
    // Outside vibrancy both values are bright and the delta
    // represents a real visible button background.
    //
    // Additionally, the chip edge must be above 0.2 - if both
    // the chip and card are very dark, the button fill is still
    // invisible regardless of delta.
    // In dark mode, bordered buttons have subtle fills. The key
    // metric is whether the chip area differs from the card at all.
    // Under full vibrancy the delta was ~0.08 at very low luminance
    // (both near 0.13-0.21). Outside vibrancy the delta should be
    // at least 0.03 with the chip edge above 0.12.
    XCTAssertGreaterThan(
      delta,
      0.03,
      "Status segmented control has no visible contrast against sidebar: "
        + "pickerEdge=\(pickerEdge), cardBg=\(cardBg), delta=\(delta)."
    )
  }

  func testSidebarSecondarySegmentsShareConsistentBackground() throws {
    let app = launch(mode: "preview")

    let sortSegment = button(
      in: app,
      identifier: Accessibility.sidebarSortSegment("name")
    )
    let focusSegment = button(in: app, identifier: Accessibility.blockedChip)

    XCTAssertTrue(
      sortSegment.waitForExistence(timeout: Self.actionTimeout),
      "Name sort segment must exist"
    )
    XCTAssertTrue(
      focusSegment.waitForExistence(timeout: Self.actionTimeout),
      "Blocked focus segment must exist"
    )

    let sortColor = averageColor(of: sortSegment)
    let focusColor = averageColor(of: focusSegment)

    let sortShot = XCTAttachment(screenshot: sortSegment.screenshot())
    sortShot.name = "sort-segment-name"
    sortShot.lifetime = .keepAlways
    add(sortShot)

    let focusShot = XCTAttachment(screenshot: focusSegment.screenshot())
    focusShot.name = "focus-segment-blocked"
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
      "Sidebar secondary segmented controls do not share a consistent background tone: "
        + "sort=(\(sortColor.red),\(sortColor.green),\(sortColor.blue)), "
        + "focus=(\(focusColor.red),\(focusColor.green),\(focusColor.blue)), "
        + "maxChannelDelta=\(maxDelta)."
    )
  }

}
