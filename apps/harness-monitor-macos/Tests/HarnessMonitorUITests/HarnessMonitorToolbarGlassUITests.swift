import AppKit
import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorToolbarGlassUITests: HarnessMonitorUITestCase {
  func testActiveBackdropTintsDetailWithoutChangingSidebarBoundaryChrome() throws {
    let dashboardMeasurement = measureSplitBoundaryTint(
      additionalEnvironment: [
        "HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard-landing",
        "HARNESS_MONITOR_KEEP_ANIMATIONS": "1",
      ]
    )
    let cockpitMeasurement = measureSplitBoundaryTint(
      selectsPreviewSession: true,
      additionalEnvironment: [
        "HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard-landing",
        "HARNESS_MONITOR_KEEP_ANIMATIONS": "1",
      ]
    )

    XCTAssertGreaterThan(
      cockpitMeasurement.detailToolbar.greenDominance,
      0.03,
      """
      Detail toolbar lost too much of the active-banner tint at the split boundary: \
      \(cockpitMeasurement.debugDescription)
      """
    )
    XCTAssertLessThan(
      cockpitMeasurement.sidebarToolbar.distance(to: dashboardMeasurement.sidebarToolbar),
      0.01,
      """
      Sidebar toolbar chrome at x=260, y=10 should stay aligned with the \
      dashboard baseline when the cockpit backdrop is active.

      dashboard: \(dashboardMeasurement.debugDescription)
      cockpit: \(cockpitMeasurement.debugDescription)
      """
    )
    XCTAssertLessThan(
      cockpitMeasurement.sidebarBelowToolbar.distance(
        to: dashboardMeasurement.sidebarBelowToolbar
      ),
      0.01,
      """
      Sidebar content just below the toolbar should stay aligned with the \
      dashboard baseline when the cockpit backdrop is active.

      dashboard: \(dashboardMeasurement.debugDescription)
      cockpit: \(cockpitMeasurement.debugDescription)
      """
    )
  }

  func testDashboardDoesNotRenderStatusCornerChrome() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: [
        "HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard-landing",
        "HARNESS_MONITOR_UI_MAIN_WINDOW_WIDTH": "960",
        "HARNESS_MONITOR_UI_MAIN_WINDOW_HEIGHT": "720",
      ]
    )
    let toolbarChromeState = element(in: app, identifier: Accessibility.toolbarChromeState)
    let statusCorner = frameElement(
      in: app,
      identifier: Accessibility.sessionStatusCornerFrame
    )

    XCTAssertTrue(
      toolbarChromeState.waitForExistence(timeout: Self.actionTimeout),
      "The dashboard scenario should expose toolbar chrome state markers"
    )
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        toolbarChromeState.label.contains("windowTitle=Dashboard")
      },
      "The dashboard scenario should keep the main window in dashboard mode"
    )
    XCTAssertFalse(
      statusCorner.exists,
      "Dashboard should not render cockpit-only status corner chrome"
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
        [
          "HARNESS_MONITOR_SHOW_INSPECTOR_OVERRIDE": "1",
          "HARNESS_MONITOR_UI_MAIN_WINDOW_WIDTH": "960",
          "HARNESS_MONITOR_UI_MAIN_WINDOW_HEIGHT": "720",
        ]
      ) { _, new in new }
    )
    let toolbar = mainWindow(in: app).toolbars.firstMatch
    let anchor = toolbarMeasurementAnchor(in: app)

    XCTAssertTrue(toolbar.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(anchor.waitForExistence(timeout: Self.actionTimeout))
    ensureInspectorIsVisible(in: app)

    Thread.sleep(forTimeInterval: 0.9)
    let initial = toolbarGlassStats(in: app, toolbar: toolbar, anchor: anchor)

    tapButton(in: app, identifier: Accessibility.inspectorToggleButton)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
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
    selectsPreviewSession: Bool = false,
    additionalEnvironment: [String: String]
  ) -> SplitBoundaryTintMeasurement {
    let app = launch(
      mode: "preview",
      additionalEnvironment: additionalEnvironment.merging(
        [
          "HARNESS_MONITOR_SHOW_INSPECTOR_OVERRIDE": "1",
          "HARNESS_MONITOR_UI_MAIN_WINDOW_WIDTH": "960",
          "HARNESS_MONITOR_UI_MAIN_WINDOW_HEIGHT": "720",
        ]
      ) { _, new in new }
    )
    let toolbarChromeState = element(in: app, identifier: Accessibility.toolbarChromeState)
    let appChromeState = element(in: app, identifier: Accessibility.appChromeState)

    if selectsPreviewSession {
      XCTAssertTrue(toolbarChromeState.waitForExistence(timeout: Self.actionTimeout))
      XCTAssertTrue(appChromeState.waitForExistence(timeout: Self.actionTimeout))
      XCTAssertTrue(
        waitUntil(timeout: Self.actionTimeout) {
          toolbarChromeState.label.contains("windowTitle=Dashboard")
        },
        "The split-boundary regression must start from the dashboard before selecting a session"
      )
      let sessionRow = previewSessionTrigger(in: app)
      XCTAssertTrue(waitForElement(sessionRow, timeout: Self.actionTimeout))
      tapPreviewSession(in: app)
      XCTAssertTrue(
        waitUntil(timeout: Self.actionTimeout) {
          toolbarChromeState.label.contains("windowTitle=Cockpit")
        },
        "Selecting the preview session should switch the window into cockpit mode"
      )
    }

    let window = mainWindow(in: app)
    let toolbar = window.toolbars.firstMatch
    let sidebar = frameElement(in: app, identifier: Accessibility.sidebarShellFrame)
    let contentRoot = frameElement(in: app, identifier: Accessibility.contentRootFrame)

    XCTAssertTrue(toolbar.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(appChromeState.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(sidebar.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(contentRoot.waitForExistence(timeout: Self.actionTimeout))

    Thread.sleep(forTimeInterval: 0.6)

    let screenshot = window.screenshot()
    guard let cgImage = screenshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else {
      XCTFail("Could not capture window screenshot")
      return .zero
    }

    let scaleX = CGFloat(cgImage.width) / window.frame.width
    let scaleY = CGFloat(cgImage.height) / window.frame.height
    let windowOrigin = window.frame.origin
    let toolbarFrame = toolbar.frame
    let sidebarFrame = sidebar.frame
    let contentFrame = contentRoot.frame

    let toolbarProbeHeight = 2.0
    let sidebarProbeX = max(sidebarFrame.maxX - windowOrigin.x - 8, 0)
    let detailProbeX = max(contentFrame.minX - windowOrigin.x + 8, 0)
    let toolbarProbeY = max(toolbarFrame.minY - windowOrigin.y + 10, 0)
    let belowToolbarProbeY = max(toolbarFrame.maxY - windowOrigin.y + 1, 0)

    let sidebarToolbarRect = CGRect(
      x: sidebarProbeX,
      y: toolbarProbeY,
      width: 2,
      height: toolbarProbeHeight
    )
    let sidebarBelowToolbarRect = CGRect(
      x: sidebarProbeX,
      y: belowToolbarProbeY,
      width: 2,
      height: 2
    )
    let detailToolbarRect = CGRect(
      x: detailProbeX,
      y: toolbarProbeY,
      width: 4,
      height: toolbarProbeHeight
    )

    let sidebarToolbarColor = sampleAverageColor(
      image: cgImage,
      rect: scaledRect(sidebarToolbarRect, scaleX: scaleX, scaleY: scaleY)
    )
    let sidebarBelowToolbarColor = sampleAverageColor(
      image: cgImage,
      rect: scaledRect(
        sidebarBelowToolbarRect,
        scaleX: scaleX,
        scaleY: scaleY
      )
    )
    let detailToolbarColor = sampleAverageColor(
      image: cgImage,
      rect: scaledRect(detailToolbarRect, scaleX: scaleX, scaleY: scaleY)
    )

    let debugContext =
      """
      appChromeState=\(appChromeState.label)
      toolbarChromeState=\(toolbarChromeState.label)
      sidebarFrame=\(NSStringFromRect(sidebarFrame))
      contentFrame=\(NSStringFromRect(contentFrame))
      toolbarFrame=\(NSStringFromRect(toolbarFrame))
      """
    let measurement = SplitBoundaryTintMeasurement(
      sidebarToolbar: sidebarToolbarColor,
      sidebarBelowToolbar: sidebarBelowToolbarColor,
      detailToolbar: detailToolbarColor,
      debugContext: debugContext
    )
    attachDiagnostic(measurement.debugDescription, named: "split-boundary-tint")
    attachWindowScreenshot(in: app, named: "split-boundary-tint")
    return measurement
  }

  private func toolbarMeasurementAnchor(in app: XCUIApplication) -> XCUIElement {
    frameElement(in: app, identifier: Accessibility.contentRootFrame)
  }

  private func ensureInspectorIsVisible(in app: XCUIApplication) {
    let toggleButton = toolbarButton(in: app, identifier: Accessibility.inspectorToggleButton)

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        toggleButton.exists
      })

    if element(in: app, identifier: Accessibility.inspectorRoot).exists {
      return
    }

    tapButton(in: app, identifier: Accessibility.inspectorToggleButton)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
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
    guard let cgImage = screenshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else {
      XCTFail("Could not capture window screenshot")
      return .zero
    }

    let scaleX = CGFloat(cgImage.width) / window.frame.width
    let scaleY = CGFloat(cgImage.height) / window.frame.height
    let windowOrigin = window.frame.origin
    let toolbarFrame = toolbar.frame
    let anchorFrame = anchor.frame
    let sampleWidth = min(anchorFrame.width * 0.4, 220)
    let sampleX = anchorFrame.midX - (sampleWidth / 2)

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
