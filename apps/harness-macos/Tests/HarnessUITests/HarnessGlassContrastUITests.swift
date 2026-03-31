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

  // MARK: - Pixel analysis

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
