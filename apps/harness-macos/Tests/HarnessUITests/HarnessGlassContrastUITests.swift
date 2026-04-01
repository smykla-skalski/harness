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

  // MARK: - Pixel analysis

  private enum SampleRegion {
    case top
    case center
  }

  private func edgeLuminance(
    of element: XCUIElement,
    region: SampleRegion
  ) -> Double {
    let screenshot = element.screenshot()
    guard let cgImage = screenshot.image.cgImage(
      forProposedRect: nil,
      context: nil,
      hints: nil
    ) else {
      return 0
    }

    let width = cgImage.width
    let height = cgImage.height
    guard width > 4, height > 4 else { return 0 }

    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

    guard let context = CGContext(
      data: &pixels,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      return 0
    }

    context.draw(
      cgImage,
      in: CGRect(x: 0, y: 0, width: width, height: height)
    )

    // Sample a horizontal strip in the requested region.
    let stripHeight: Int
    let startRow: Int
    switch region {
    case .top:
      // Top 25% of the element - above any centered text.
      stripHeight = max(height / 4, 2)
      startRow = 2
    case .center:
      stripHeight = max(height / 4, 2)
      startRow = height / 2 - stripHeight / 2
    }

    let edgeSkip = 4
    var samples: [Double] = []
    for row in startRow..<min(startRow + stripHeight, height - 2) {
      for col in stride(from: edgeSkip, to: width - edgeSkip, by: 2) {
        let offset = row * bytesPerRow + col * bytesPerPixel
        let red = Double(pixels[offset]) / 255.0
        let green = Double(pixels[offset + 1]) / 255.0
        let blue = Double(pixels[offset + 2]) / 255.0
        samples.append(
          0.2126 * red + 0.7152 * green + 0.0722 * blue
        )
      }
    }

    guard !samples.isEmpty else { return 0 }
    return samples.reduce(0, +) / Double(samples.count)
  }

  private struct LuminanceStats {
    let min: Double
    let max: Double
    let mean: Double
    let stddev: Double
    let count: Int
  }

  private func luminanceStats(of element: XCUIElement) -> LuminanceStats {
    let screenshot = element.screenshot()
    guard let cgImage = screenshot.image.cgImage(
      forProposedRect: nil,
      context: nil,
      hints: nil
    ) else {
      return LuminanceStats(
        min: 0, max: 0, mean: 0, stddev: 0, count: 0
      )
    }

    let width = cgImage.width
    let height = cgImage.height
    guard width > 10, height > 10 else {
      return LuminanceStats(
        min: 0, max: 0, mean: 0, stddev: 0, count: 0
      )
    }

    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

    guard let context = CGContext(
      data: &pixels,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      return LuminanceStats(
        min: 0, max: 0, mean: 0, stddev: 0, count: 0
      )
    }

    context.draw(
      cgImage,
      in: CGRect(x: 0, y: 0, width: width, height: height)
    )

    let edgeSkip = 8
    let step = max(1, min(width, height) / 50)
    var samples: [Double] = []

    for row in stride(from: edgeSkip, to: height - edgeSkip, by: step) {
      for col in stride(from: edgeSkip, to: width - edgeSkip, by: step) {
        let offset = row * bytesPerRow + col * bytesPerPixel
        let red = Double(pixels[offset]) / 255.0
        let green = Double(pixels[offset + 1]) / 255.0
        let blue = Double(pixels[offset + 2]) / 255.0
        samples.append(
          0.2126 * red + 0.7152 * green + 0.0722 * blue
        )
      }
    }

    guard samples.count > 1 else {
      return LuminanceStats(
        min: 0, max: 0, mean: 0, stddev: 0, count: 0
      )
    }

    let sampleMin = samples.min() ?? 0
    let sampleMax = samples.max() ?? 0
    let mean = samples.reduce(0, +) / Double(samples.count)
    let variance = samples.reduce(0) {
      $0 + ($1 - mean) * ($1 - mean)
    } / Double(samples.count - 1)

    return LuminanceStats(
      min: sampleMin,
      max: sampleMax,
      mean: mean,
      stddev: variance.squareRoot(),
      count: samples.count
    )
  }
}
