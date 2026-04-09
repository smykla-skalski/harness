import AppKit
import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorFocusRingUITests: HarnessMonitorUITestCase {

  func testSidebarSearchFieldFocusRingAppearsImmediatelyOnFirstClick() throws {
    let app = launch(mode: "preview")

    let searchField = editableField(in: app, identifier: "harness.sidebar.search")
    XCTAssertTrue(searchField.waitForExistence(timeout: Self.actionTimeout))

    if fieldHasFocusRingPixels(searchField, in: app) {
      tapPreviewSession(in: app)
      XCTAssertTrue(
        waitUntil(timeout: 1, pollInterval: 0.02) {
          !self.fieldHasFocusRingPixels(searchField, in: app)
        },
        "Search field unexpectedly remained focused before the click-latency check"
      )
    }

    if searchField.isHittable {
      searchField.tap()
    } else if let coordinate = centerCoordinate(in: app, for: searchField) {
      coordinate.tap()
    } else {
      XCTFail("Failed to tap sidebar search field")
    }

    let focusRingAppearedQuickly = waitUntil(timeout: 0.12, pollInterval: 0.01) {
      self.fieldHasFocusRingPixels(searchField, in: app)
    }

    attachWindowScreenshot(in: app, named: "focus-ring-sidebar-search-click")
    XCTAssertTrue(
      focusRingAppearedQuickly,
      "Sidebar search field focus ring did not appear within 120ms of the first click"
    )
  }

  /// Verify the focus ring around a sidebar session card follows the
  /// rounded rectangle shape of the card rather than being a plain
  /// rectangle.
  ///
  /// Strategy: Tab-focus the session row, screenshot the window, then
  /// sample the four corners of the session row frame. A rectangular
  /// focus ring paints blue at those corners; a properly rounded one
  /// leaves them matching the dark sidebar background.
  func testSessionCardFocusRingFollowsRoundedShape() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: [
        "AppleKeyboardUIMode": "2"
      ]
    )

    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))

    // Tab through controls until the session row gains keyboard focus.
    // The preview mode has a search field and filter controls above
    // the session list, so we need several Tab presses.
    let window = mainWindow(in: app)
    for _ in 0..<20 {
      window.typeKey(.tab, modifierFlags: [])
      RunLoop.current.run(until: Date.now.addingTimeInterval(0.15))

      // Check if the session row now has keyboard focus by looking
      // for the focus ring: the system draws a ~3pt blue border
      // around the focused element, which inflates its visual bounds.
      // We detect this by checking if bright blue pixels appear near
      // the session row edges.
      if sessionRowHasFocusRingPixels(sessionRow, in: app) {
        break
      }
    }

    // Capture evidence for manual inspection regardless of outcome.
    attachWindowScreenshot(in: app, named: "focus-ring-session-card")

    // The session row must have received focus for the test to be valid.
    XCTAssertTrue(
      sessionRowHasFocusRingPixels(sessionRow, in: app),
      "Session row never received keyboard focus after tabbing"
    )

    // Now verify the focus ring is rounded, not rectangular.
    // Sample the four extreme corners of the session row frame.
    // The system focus ring extends ~3pt outside the element bounds,
    // so we sample at (frame.minX - 1, frame.minY - 1) etc.
    // For a rounded rect with cornerRadius ~12pt, pixels at the
    // very corner of the bounding box should NOT be blue - they
    // should be the dark sidebar background.
    assertFocusRingCornersAreRounded(sessionRow, in: app)
  }

  // MARK: - Helpers

  private func fieldHasFocusRingPixels(
    _ field: XCUIElement,
    in app: XCUIApplication
  ) -> Bool {
    let screenshot = field.screenshot()
    guard
      let cgImage = screenshot.image.cgImage(
        forProposedRect: nil,
        context: nil,
        hints: nil
      )
    else { return false }

    let probes: [(Int, Int)] = [
      (2, max(cgImage.height / 2, 2)),
      (max(cgImage.width / 2, 2), 2),
      (max(cgImage.width - 3, 2), max(cgImage.height / 2, 2)),
      (max(cgImage.width / 2, 2), max(cgImage.height - 3, 2)),
    ]

    for (probeX, probeY) in probes
    where probeX > 0 && probeY > 0 && probeX < cgImage.width && probeY < cgImage.height {
      let color = pixelColor(in: cgImage, x: probeX, y: probeY)
      if color.blue > 0.4 && color.blue > color.red * 1.3 {
        return true
      }
    }

    return false
  }

  /// Returns true if the area around the session row contains the
  /// characteristic blue focus ring color.
  private func sessionRowHasFocusRingPixels(
    _ row: XCUIElement,
    in app: XCUIApplication
  ) -> Bool {
    let window = mainWindow(in: app)
    let screenshot = window.screenshot()
    guard
      let cgImage = screenshot.image.cgImage(
        forProposedRect: nil,
        context: nil,
        hints: nil
      )
    else { return false }

    let scale = CGFloat(cgImage.width) / window.frame.width
    let rowFrame = row.frame

    // Sample the left edge center of the row, offset 2pt outside.
    let probeX = Int((rowFrame.minX - window.frame.minX - 2) * scale)
    let probeY = Int((rowFrame.midY - window.frame.minY) * scale)

    guard probeX > 0, probeY > 0,
      probeX < cgImage.width, probeY < cgImage.height
    else { return false }

    let color = pixelColor(in: cgImage, x: probeX, y: probeY)
    // Focus ring blue: high blue channel relative to red/green.
    return color.blue > 0.4 && color.blue > color.red * 1.3
  }

  /// Assert that the focus ring corners are rounded by checking that
  /// the extreme corner pixels of the row's bounding box do NOT have
  /// the focus ring blue color.
  private func assertFocusRingCornersAreRounded(
    _ row: XCUIElement,
    in app: XCUIApplication
  ) {
    let window = mainWindow(in: app)
    let screenshot = window.screenshot()
    guard
      let cgImage = screenshot.image.cgImage(
        forProposedRect: nil,
        context: nil,
        hints: nil
      )
    else {
      XCTFail("Could not capture window screenshot")
      return
    }

    let scale = CGFloat(cgImage.width) / window.frame.width
    let rowFrame = row.frame
    let windowOrigin = window.frame.origin

    // The focus ring extends ~3-4pt outside the element bounds.
    // We probe 2pt outside each corner of the element frame.
    // For a rounded rect with radius ~12pt, these should NOT be
    // blue because the rounded corner curves away from the corner.
    let cornerOffset: CGFloat = 2
    let corners: [(String, CGFloat, CGFloat)] = [
      (
        "top-left",
        rowFrame.minX - windowOrigin.x - cornerOffset,
        rowFrame.minY - windowOrigin.y - cornerOffset
      ),
      (
        "top-right",
        rowFrame.maxX - windowOrigin.x + cornerOffset,
        rowFrame.minY - windowOrigin.y - cornerOffset
      ),
      (
        "bottom-left",
        rowFrame.minX - windowOrigin.x - cornerOffset,
        rowFrame.maxY - windowOrigin.y + cornerOffset
      ),
      (
        "bottom-right",
        rowFrame.maxX - windowOrigin.x + cornerOffset,
        rowFrame.maxY - windowOrigin.y + cornerOffset
      ),
    ]

    for (name, x, y) in corners {
      let pixelX = Int(x * scale)
      let pixelY = Int(y * scale)

      guard pixelX > 0, pixelY > 0,
        pixelX < cgImage.width, pixelY < cgImage.height
      else { continue }

      let color = pixelColor(in: cgImage, x: pixelX, y: pixelY)
      let isFocusRingBlue = color.blue > 0.4 && color.blue > color.red * 1.3

      XCTAssertFalse(
        isFocusRingBlue,
        "Focus ring is rectangular: blue focus ring pixel found at "
          + "\(name) corner (r=\(String(format: "%.2f", color.red)), "
          + "g=\(String(format: "%.2f", color.green)), "
          + "b=\(String(format: "%.2f", color.blue)))"
      )
    }
  }

  /// Read a single pixel's color from a CGImage.
  private func pixelColor(in image: CGImage, x: Int, y: Int) -> RGBColor {
    let bytesPerPixel = 4
    let bytesPerRow = image.width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: image.height * bytesPerRow)

    guard
      let context = CGContext(
        data: &pixels,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else {
      return RGBColor(red: 0, green: 0, blue: 0)
    }

    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

    let offset = y * bytesPerRow + x * bytesPerPixel
    guard offset + 3 < pixels.count else {
      return RGBColor(red: 0, green: 0, blue: 0)
    }

    return RGBColor(
      red: Double(pixels[offset]) / 255.0,
      green: Double(pixels[offset + 1]) / 255.0,
      blue: Double(pixels[offset + 2]) / 255.0
    )
  }
}
