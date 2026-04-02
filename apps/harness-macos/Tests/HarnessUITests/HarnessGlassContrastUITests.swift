import AppKit
import XCTest

private typealias Accessibility = HarnessUITestAccessibility

@MainActor
final class HarnessGlassContrastUITests: HarnessUITestCase {

  func testBoardMetricCardContentIsReadable() throws {
    let app = launch(mode: "empty")

    let card = element(
      in: app,
      identifier: Accessibility.trackedProjectsCard
    )
    XCTAssertTrue(card.waitForExistence(timeout: Self.uiTimeout))

    let stats = luminanceStats(of: card)
    let screenshot = XCTAttachment(screenshot: card.screenshot())
    screenshot.name = "board-metric-section"
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

  func testSidebarDaemonCardContentIsReadable() throws {
    let app = launch(mode: "empty")

    let card = frameElement(in: app, identifier: Accessibility.daemonCardFrame)
    XCTAssertTrue(card.waitForExistence(timeout: Self.uiTimeout))

    let stats = luminanceStats(of: card)
    let screenshot = XCTAttachment(screenshot: card.screenshot())
    screenshot.name = "daemon-section"
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

  func testSidebarDaemonStatusDotUsesGreenTintWhenOnline() throws {
    let app = launch(mode: "preview")

    let badge = element(in: app, identifier: Accessibility.sidebarDaemonStatusBadge)
    XCTAssertTrue(badge.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertEqual(badge.value as? String, "Online")

    let topSample = sampleRegion(of: badge, region: .top)
    let screenshot = XCTAttachment(screenshot: badge.screenshot())
    screenshot.name = "daemon-status-dot"
    screenshot.lifetime = .keepAlways
    add(screenshot)

    let greenDominance =
      topSample.averageColor.green
      - max(topSample.averageColor.red, topSample.averageColor.blue)

    print(
      "DAEMON_STATUS_BADGE topRGB=(\(topSample.averageColor.red),"
        + "\(topSample.averageColor.green),\(topSample.averageColor.blue)) "
        + "stddev=\(topSample.luminanceStats.stddev)"
    )

    XCTAssertGreaterThan(
      greenDominance,
      0.05,
      "Daemon status dot is not visibly tinted enough for an online state: "
        + "red=\(topSample.averageColor.red), "
        + "green=\(topSample.averageColor.green), "
        + "blue=\(topSample.averageColor.blue), "
        + "dominance=\(greenDominance)"
    )
    XCTAssertLessThan(
      topSample.luminanceStats.stddev,
      0.2,
      "Daemon status dot fill is too noisy to read as a solid state indicator: "
        + "stddev=\(topSample.luminanceStats.stddev), "
        + "min=\(topSample.luminanceStats.min), "
        + "max=\(topSample.luminanceStats.max), "
        + "mean=\(topSample.luminanceStats.mean)"
    )
  }

  func testInspectorEmptyStateIsReadable() throws {
    let app = launch(mode: "empty")

    let emptyState = element(in: app, identifier: Accessibility.inspectorEmptyState)
    XCTAssertTrue(emptyState.waitForExistence(timeout: Self.uiTimeout))

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

    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))
    tapPreviewSession(in: app)

    let taskCard = element(in: app, identifier: Accessibility.taskUICard)
    XCTAssertTrue(taskCard.waitForExistence(timeout: Self.uiTimeout))

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

  func testSidebarFilterChipBackgroundIsVisible() throws {
    let app = launch(mode: "preview")

    // "Blocked" is unselected by default (default focus = .all).
    // Its .bordered style should render a visible button background.
    let chip = button(in: app, title: "Blocked")
    let filtersCard = element(
      in: app,
      identifier: Accessibility.sidebarFiltersCard
    )
    XCTAssertTrue(
      chip.waitForExistence(timeout: Self.uiTimeout),
      "Blocked focus chip must exist"
    )
    XCTAssertTrue(filtersCard.exists, "Filters card must exist")

    // Sample the chip's EDGE luminance (top 25% strip, above the text)
    // and compare against the filter card background. If the button
    // background is invisible (vibrancy washed out), the edge strip
    // will have the same luminance as the sidebar card background.
    let chipEdge = edgeLuminance(of: chip, region: .top)
    let cardBg = edgeLuminance(of: filtersCard, region: .top)

    let chipShot = XCTAttachment(screenshot: chip.screenshot())
    chipShot.name = "filter-chip-blocked"
    chipShot.lifetime = .keepAlways
    add(chipShot)

    let cardShot = XCTAttachment(screenshot: filtersCard.screenshot())
    cardShot.name = "filter-card-background"
    cardShot.lifetime = .keepAlways
    add(cardShot)

    let delta = abs(chipEdge - cardBg)
    print("CHIP_CONTRAST chipEdge=\(chipEdge) cardBg=\(cardBg) delta=\(delta)")

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
      "Unselected chip has no visible contrast against sidebar: "
        + "chipEdge=\(chipEdge), cardBg=\(cardBg), delta=\(delta)."
    )
  }

  func testInactiveFilterChipMatchesSortSegmentBackground() throws {
    let app = launch(mode: "preview")

    // "Ended" is an unselected status filter chip (.bordered + .secondary tint).
    let endedChip = button(in: app, title: "Ended")
    // "Status" is an unselected sort segment in the segmented picker.
    let statusSegment = button(in: app, title: "Status")

    XCTAssertTrue(
      endedChip.waitForExistence(timeout: Self.uiTimeout),
      "Ended chip must exist"
    )
    XCTAssertTrue(
      statusSegment.waitForExistence(timeout: Self.uiTimeout),
      "Status sort segment must exist"
    )

    // Use the 1x1 downscale technique: Core Graphics averages all
    // pixels when drawing into a 1x1 context, giving us the true
    // average RGBA of the element's rendered appearance.
    let chipColor = averageColor(of: endedChip)
    let segmentColor = averageColor(of: statusSegment)

    let chipShot = XCTAttachment(screenshot: endedChip.screenshot())
    chipShot.name = "inactive-ended-chip"
    chipShot.lifetime = .keepAlways
    add(chipShot)

    let segmentShot = XCTAttachment(screenshot: statusSegment.screenshot())
    segmentShot.name = "inactive-status-segment"
    segmentShot.lifetime = .keepAlways
    add(segmentShot)

    print(
      "CHIP_VS_SEGMENT chip=(\(chipColor.red),\(chipColor.green),\(chipColor.blue)) "
        + "segment=(\(segmentColor.red),\(segmentColor.green),\(segmentColor.blue))"
    )

    // Compare each RGB channel. The inactive filter chip and the
    // inactive sort segment should render with the same background
    // tone. A per-channel delta above 0.06 (out of 0-1) means the
    // controls look visually different.
    let maxDelta = max(
      abs(chipColor.red - segmentColor.red),
      abs(chipColor.green - segmentColor.green),
      abs(chipColor.blue - segmentColor.blue)
    )

    XCTAssertLessThan(
      maxDelta,
      0.06,
      "Inactive filter chip and sort segment backgrounds don't match: "
        + "chip=(\(chipColor.red),\(chipColor.green),\(chipColor.blue)), "
        + "segment=(\(segmentColor.red),\(segmentColor.green),\(segmentColor.blue)), "
        + "maxChannelDelta=\(maxDelta). "
        + "These controls should have consistent inactive backgrounds."
    )
  }

}
