import AppKit
import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorToolbarGlassUITests: HarnessMonitorUITestCase {
  func testActiveBannerTintCarriesIntoDetailToolbarAtSplitBoundary() throws {
    let measurement = measureSplitBoundaryTint(
      additionalEnvironment: [
        "HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit",
        "HARNESS_MONITOR_KEEP_ANIMATIONS": "1",
      ]
    )

    XCTAssertGreaterThan(
      measurement.sidebar.greenDominance,
      0.01,
      "Sidebar sample did not pick up the active-banner tint: \(measurement.debugDescription)"
    )
    XCTAssertGreaterThan(
      measurement.detail.greenDominance,
      measurement.sidebar.greenDominance * 0.6,
      "Detail toolbar lost too much of the active-banner tint at the split boundary: \(measurement.debugDescription)"
    )
  }

  func testCockpitToolbarRetainsGlassAfterInspectorCycle() throws {
    let result = measureToolbarGlass(
      additionalEnvironment: [
        "HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit",
        "HARNESS_MONITOR_KEEP_ANIMATIONS": "1",
      ]
    )

    XCTAssertGreaterThan(
      result.initial.stddev,
      0.02,
      "Expected the controlled cockpit probe to be visible through the starting toolbar glass"
    )
    XCTAssertGreaterThan(
      result.afterClose.stddev,
      result.initial.stddev * 0.7,
      "Toolbar glass collapsed after closing the inspector on the active cockpit"
    )
  }

  func testCockpitToolbarTurnsOpaqueWhenInstantFocusRingSwapIsReenabled() throws {
    let result = measureToolbarGlass(
      additionalEnvironment: [
        "HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit",
        "HARNESS_MONITOR_KEEP_ANIMATIONS": "1",
        "HARNESS_MONITOR_FORCE_INSTANT_FOCUS_RING": "1",
      ]
    )

    XCTAssertLessThan(
      result.afterClose.stddev,
      result.initial.stddev * 0.5,
      "The ISA-swizzled window did not reproduce the opaque-toolbar regression on the cockpit"
    )
  }

  func testCockpitToolbarRetainsGlassWithoutContentDetailChrome() throws {
    let result = measureToolbarGlass(
      additionalEnvironment: [
        "HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit",
        "HARNESS_MONITOR_KEEP_ANIMATIONS": "1",
        "HARNESS_MONITOR_DISABLE_CONTENT_DETAIL_CHROME": "1",
      ]
    )

    XCTAssertGreaterThan(
      result.afterClose.stddev,
      result.initial.stddev * 0.7,
      "Removing the detail chrome wrapper should keep the cockpit toolbar material intact"
    )
  }

  func testCockpitToolbarRetainsGlassWithoutBaselineOverlay() throws {
    let result = measureToolbarGlass(
      additionalEnvironment: [
        "HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit",
        "HARNESS_MONITOR_KEEP_ANIMATIONS": "1",
        "HARNESS_MONITOR_DISABLE_TOOLBAR_BASELINE_OVERLAY": "1",
      ]
    )

    XCTAssertGreaterThan(
      result.afterClose.stddev,
      result.initial.stddev * 0.7,
      "Removing the custom toolbar baseline overlay should keep the cockpit toolbar material intact"
    )
  }

  private func measureToolbarGlass(
    additionalEnvironment: [String: String]
  ) -> ToolbarGlassMeasurement {
    let app = launch(
      mode: "preview",
      additionalEnvironment: additionalEnvironment.merging(
        ["HARNESS_MONITOR_SHOW_INSPECTOR_OVERRIDE": "1"]
      ) { _, new in new }
    )
    let toolbar = mainWindow(in: app).toolbars.firstMatch
    let anchor = toolbarMeasurementAnchor(in: app)

    XCTAssertTrue(toolbar.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(anchor.waitForExistence(timeout: Self.actionTimeout))
    if additionalEnvironment["HARNESS_MONITOR_DISABLE_CONTENT_DETAIL_CHROME"] != "1" {
      XCTAssertTrue(
        element(in: app, identifier: Accessibility.sessionStatusBanner).waitForExistence(
          timeout: Self.actionTimeout
        ),
        "Expected the active-session banner to be visible for the cockpit glass regression"
      )
    }
    ensureInspectorIsVisible(in: app)

    Thread.sleep(forTimeInterval: 0.9)
    let initial = toolbarGlassStats(in: app, toolbar: toolbar, anchor: anchor)

    tapButton(in: app, identifier: Accessibility.inspectorToggleButton)
    XCTAssertTrue(waitUntil(timeout: Self.actionTimeout) {
      self.toolbarButton(in: app, identifier: Accessibility.inspectorToggleButton).exists
    })
    Thread.sleep(forTimeInterval: 1.1)

    let afterClose = toolbarGlassStats(in: app, toolbar: toolbar, anchor: anchor)

    let diagnostics = """
      initial: \(initial.debugDescription)
      afterClose: \(afterClose.debugDescription)
      """
    attachDiagnostic(diagnostics, named: "toolbar-glass-metrics")
    attachWindowScreenshot(in: app, named: "cockpit-toolbar-glass")

    return ToolbarGlassMeasurement(initial: initial, afterClose: afterClose)
  }

  private func measureSplitBoundaryTint(
    additionalEnvironment: [String: String]
  ) -> SplitBoundaryTintMeasurement {
    let app = launch(
      mode: "preview",
      additionalEnvironment: additionalEnvironment.merging(
        ["HARNESS_MONITOR_SHOW_INSPECTOR_OVERRIDE": "1"]
      ) { _, new in new }
    )
    let window = mainWindow(in: app)
    let toolbar = window.toolbars.firstMatch
    let sidebar = frameElement(in: app, identifier: Accessibility.sidebarShellFrame)
    let statusBanner = element(in: app, identifier: Accessibility.sessionStatusBanner)

    XCTAssertTrue(toolbar.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(sidebar.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(statusBanner.waitForExistence(timeout: Self.actionTimeout))

    Thread.sleep(forTimeInterval: 0.6)

    let screenshot = window.screenshot()
    guard let cgImage = screenshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      XCTFail("Could not capture window screenshot")
      return .zero
    }

    let scaleX = CGFloat(cgImage.width) / window.frame.width
    let scaleY = CGFloat(cgImage.height) / window.frame.height
    let windowOrigin = window.frame.origin
    let toolbarFrame = toolbar.frame
    let sidebarFrame = sidebar.frame
    let statusFrame = statusBanner.frame

    let sidebarRect = CGRect(
      x: max(sidebarFrame.maxX - windowOrigin.x - 72, 0),
      y: max(toolbarFrame.minY - windowOrigin.y + 8, 0),
      width: 56,
      height: max(toolbarFrame.height - 16, 1)
    )
    let detailRect = CGRect(
      x: max(statusFrame.minX - windowOrigin.x + 24, 0),
      y: max(toolbarFrame.minY - windowOrigin.y + 8, 0),
      width: 56,
      height: max(toolbarFrame.height - 16, 1)
    )

    let sidebarColor = sampleAverageColor(
      image: cgImage,
      rect: scaledRect(sidebarRect, scaleX: scaleX, scaleY: scaleY)
    )
    let detailColor = sampleAverageColor(
      image: cgImage,
      rect: scaledRect(detailRect, scaleX: scaleX, scaleY: scaleY)
    )

    let measurement = SplitBoundaryTintMeasurement(sidebar: sidebarColor, detail: detailColor)
    attachDiagnostic(measurement.debugDescription, named: "split-boundary-tint")
    attachWindowScreenshot(in: app, named: "split-boundary-tint")
    return measurement
  }

  private func toolbarMeasurementAnchor(in app: XCUIApplication) -> XCUIElement {
    let statusBanner = element(in: app, identifier: Accessibility.sessionStatusBanner)
    if statusBanner.exists {
      return statusBanner
    }
    return frameElement(in: app, identifier: Accessibility.contentRootFrame)
  }

  private func ensureInspectorIsVisible(in app: XCUIApplication) {
    let toggleButton = toolbarButton(in: app, identifier: Accessibility.inspectorToggleButton)

    XCTAssertTrue(waitUntil(timeout: Self.actionTimeout) {
      toggleButton.exists
    })

    if element(in: app, identifier: Accessibility.inspectorRoot).exists {
      return
    }

    tapButton(in: app, identifier: Accessibility.inspectorToggleButton)
    XCTAssertTrue(waitUntil(timeout: Self.actionTimeout) {
      self.element(in: app, identifier: Accessibility.inspectorRoot).exists
    })
  }

  private func toolbarGlassStats(
    in app: XCUIApplication,
    toolbar: XCUIElement,
    anchor: XCUIElement
  ) -> ToolbarGlassStats {
    let window = mainWindow(in: app)
    let screenshot = window.screenshot()
    guard let cgImage = screenshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      XCTFail("Could not capture window screenshot")
      return .zero
    }

    let scaleX = CGFloat(cgImage.width) / window.frame.width
    let scaleY = CGFloat(cgImage.height) / window.frame.height
    let windowOrigin = window.frame.origin
    let toolbarFrame = toolbar.frame
    let anchorFrame = anchor.frame
    let isStatusBanner = anchor.identifier == Accessibility.sessionStatusBanner
    let sampleWidth = isStatusBanner ? min(anchorFrame.width * 0.16, 120) : min(anchorFrame.width * 0.4, 220)
    let sampleX = isStatusBanner
      ? anchorFrame.minX + 24
      : anchorFrame.midX - (sampleWidth / 2)

    let sampleRect = CGRect(
      x: max(sampleX - windowOrigin.x, 0),
      y: max(toolbarFrame.minY - windowOrigin.y + 8, 0),
      width: max(sampleWidth, 1),
      height: max(toolbarFrame.height - 16, 1)
    )

    return sampleLuminanceStats(
      image: cgImage,
      rect: CGRect(
        x: sampleRect.minX * scaleX,
        y: sampleRect.minY * scaleY,
        width: sampleRect.width * scaleX,
        height: sampleRect.height * scaleY
      )
    )
  }

  private func sampleLuminanceStats(image: CGImage, rect: CGRect) -> ToolbarGlassStats {
    let bytesPerPixel = 4
    let bytesPerRow = image.width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: image.height * bytesPerRow)

    guard let context = CGContext(
      data: &pixels,
      width: image.width,
      height: image.height,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      return .zero
    }

    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

    let minX = max(Int(rect.minX.rounded(.down)), 0)
    let maxX = min(Int(rect.maxX.rounded(.up)), image.width - 1)
    let minY = max(Int(rect.minY.rounded(.down)), 0)
    let maxY = min(Int(rect.maxY.rounded(.up)), image.height - 1)
    var luminanceValues: [Double] = []

    for y in stride(from: minY, through: maxY, by: 2) {
      for x in stride(from: minX, through: maxX, by: 2) {
        let offset = y * bytesPerRow + x * bytesPerPixel
        guard offset + 2 < pixels.count else {
          continue
        }

        let red = Double(pixels[offset]) / 255.0
        let green = Double(pixels[offset + 1]) / 255.0
        let blue = Double(pixels[offset + 2]) / 255.0
        luminanceValues.append((0.299 * red) + (0.587 * green) + (0.114 * blue))
      }
    }

    guard !luminanceValues.isEmpty else {
      return .zero
    }

    let mean = luminanceValues.reduce(0, +) / Double(luminanceValues.count)
    let variance =
      luminanceValues.reduce(0) { partial, value in
        partial + ((value - mean) * (value - mean))
      } / Double(luminanceValues.count)

    return ToolbarGlassStats(
      mean: mean,
      stddev: sqrt(variance),
      sampleCount: luminanceValues.count
    )
  }

  private func sampleAverageColor(image: CGImage, rect: CGRect) -> ToolbarAverageColor {
    let bytesPerPixel = 4
    let bytesPerRow = image.width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: image.height * bytesPerRow)

    guard let context = CGContext(
      data: &pixels,
      width: image.width,
      height: image.height,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      return .zero
    }

    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

    let minX = max(Int(rect.minX.rounded(.down)), 0)
    let maxX = min(Int(rect.maxX.rounded(.up)), image.width - 1)
    let minY = max(Int(rect.minY.rounded(.down)), 0)
    let maxY = min(Int(rect.maxY.rounded(.up)), image.height - 1)
    var totalRed = 0.0
    var totalGreen = 0.0
    var totalBlue = 0.0
    var sampleCount = 0.0

    for y in stride(from: minY, through: maxY, by: 2) {
      for x in stride(from: minX, through: maxX, by: 2) {
        let offset = y * bytesPerRow + x * bytesPerPixel
        guard offset + 2 < pixels.count else {
          continue
        }

        totalRed += Double(pixels[offset]) / 255.0
        totalGreen += Double(pixels[offset + 1]) / 255.0
        totalBlue += Double(pixels[offset + 2]) / 255.0
        sampleCount += 1
      }
    }

    guard sampleCount > 0 else {
      return .zero
    }

    return ToolbarAverageColor(
      red: totalRed / sampleCount,
      green: totalGreen / sampleCount,
      blue: totalBlue / sampleCount
    )
  }

  private func scaledRect(_ rect: CGRect, scaleX: CGFloat, scaleY: CGFloat) -> CGRect {
    CGRect(
      x: rect.minX * scaleX,
      y: rect.minY * scaleY,
      width: rect.width * scaleX,
      height: rect.height * scaleY
    )
  }

  private func attachDiagnostic(_ text: String, named name: String) {
    let attachment = XCTAttachment(string: text)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}

private struct ToolbarGlassMeasurement {
  let initial: ToolbarGlassStats
  let afterClose: ToolbarGlassStats
}

private struct ToolbarGlassStats {
  let mean: Double
  let stddev: Double
  let sampleCount: Int

  static let zero = Self(mean: 0, stddev: 0, sampleCount: 0)

  var debugDescription: String {
    String(
      format: "mean=%.4f stddev=%.4f samples=%d",
      mean,
      stddev,
      sampleCount
    )
  }
}

private struct ToolbarAverageColor {
  let red: Double
  let green: Double
  let blue: Double

  static let zero = Self(red: 0, green: 0, blue: 0)

  var greenDominance: Double {
    green - max(red, blue)
  }

  var debugDescription: String {
    String(
      format: "r=%.4f g=%.4f b=%.4f greenDominance=%.4f",
      red,
      green,
      blue,
      greenDominance
    )
  }
}

private struct SplitBoundaryTintMeasurement {
  let sidebar: ToolbarAverageColor
  let detail: ToolbarAverageColor

  static let zero = Self(sidebar: .zero, detail: .zero)

  var debugDescription: String {
    "sidebar[\(sidebar.debugDescription)] detail[\(detail.debugDescription)]"
  }
}
