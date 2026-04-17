import AppKit
import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

private struct SplitBoundaryChromeState {
  let app: XCUIElement
  let toolbar: XCUIElement
}

private struct SplitBoundaryScreenshotContext {
  let window: XCUIElement
  let image: CGImage
  let scaleX: CGFloat
  let scaleY: CGFloat
  let toolbarFrame: CGRect
  let sidebarFrame: CGRect
  let contentFrame: CGRect
}

@MainActor
extension HarnessMonitorToolbarGlassUITests {
  func measureSplitBoundaryTint(
    selectsPreviewSession: Bool = false,
    additionalEnvironment: [String: String]
  ) -> SplitBoundaryTintMeasurement {
    let app = launchSplitBoundaryApp(additionalEnvironment: additionalEnvironment)
    let chromeState = splitBoundaryChromeState(in: app)

    transitionSplitBoundaryFixtureIfNeeded(
      in: app,
      chromeState: chromeState,
      selectsPreviewSession: selectsPreviewSession
    )

    guard let context = splitBoundaryScreenshotContext(in: app, chromeState: chromeState) else {
      return .zero
    }
    let measurement = splitBoundaryTintMeasurement(
      from: context,
      chromeState: chromeState
    )
    attachDiagnostic(measurement.debugDescription, named: "split-boundary-tint")
    attachWindowScreenshot(in: app, named: "split-boundary-tint")
    return measurement
  }
}

extension HarnessMonitorToolbarGlassUITests {
  fileprivate func launchSplitBoundaryApp(
    additionalEnvironment: [String: String]
  ) -> XCUIApplication {
    launch(
      mode: "preview",
      additionalEnvironment: additionalEnvironment.merging(
        [
          "HARNESS_MONITOR_SHOW_INSPECTOR_OVERRIDE": "1",
          "HARNESS_MONITOR_UI_MAIN_WINDOW_WIDTH": "960",
          "HARNESS_MONITOR_UI_MAIN_WINDOW_HEIGHT": "720",
        ]
      ) { _, new in new }
    )
  }

  fileprivate func splitBoundaryChromeState(in app: XCUIApplication) -> SplitBoundaryChromeState {
    SplitBoundaryChromeState(
      app: element(in: app, identifier: Accessibility.appChromeState),
      toolbar: element(in: app, identifier: Accessibility.toolbarChromeState)
    )
  }

  fileprivate func transitionSplitBoundaryFixtureIfNeeded(
    in app: XCUIApplication,
    chromeState: SplitBoundaryChromeState,
    selectsPreviewSession: Bool
  ) {
    guard selectsPreviewSession else {
      return
    }

    XCTAssertTrue(chromeState.toolbar.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(chromeState.app.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        chromeState.toolbar.label.contains("windowTitle=Dashboard")
      },
      "The split-boundary regression must start from the dashboard before selecting a session"
    )

    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(waitForElement(sessionRow, timeout: Self.actionTimeout))
    tapPreviewSession(in: app)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        chromeState.toolbar.label.contains("windowTitle=Cockpit")
      },
      "Selecting the preview session should switch the window into cockpit mode"
    )
  }

  fileprivate func splitBoundaryScreenshotContext(
    in app: XCUIApplication,
    chromeState: SplitBoundaryChromeState
  ) -> SplitBoundaryScreenshotContext? {
    let window = mainWindow(in: app)
    let toolbar = window.toolbars.firstMatch
    let sidebar = frameElement(in: app, identifier: Accessibility.sidebarShellFrame)
    let contentRoot = frameElement(in: app, identifier: Accessibility.contentRootFrame)

    XCTAssertTrue(toolbar.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(chromeState.app.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(sidebar.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(contentRoot.waitForExistence(timeout: Self.actionTimeout))

    Thread.sleep(forTimeInterval: 0.6)

    let screenshot = window.screenshot()
    guard let image = screenshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else {
      XCTFail("Could not capture window screenshot")
      return nil
    }

    return SplitBoundaryScreenshotContext(
      window: window,
      image: image,
      scaleX: CGFloat(image.width) / window.frame.width,
      scaleY: CGFloat(image.height) / window.frame.height,
      toolbarFrame: toolbar.frame,
      sidebarFrame: sidebar.frame,
      contentFrame: contentRoot.frame
    )
  }

  fileprivate func splitBoundaryTintMeasurement(
    from context: SplitBoundaryScreenshotContext,
    chromeState: SplitBoundaryChromeState
  ) -> SplitBoundaryTintMeasurement {
    let windowOrigin = context.window.frame.origin
    let toolbarProbeHeight = 2.0
    let sidebarProbeX = max(context.sidebarFrame.maxX - windowOrigin.x - 8, 0)
    let detailProbeX = max(context.contentFrame.minX - windowOrigin.x + 8, 0)
    let toolbarProbeY = max(context.toolbarFrame.minY - windowOrigin.y + 10, 0)
    let belowToolbarProbeY = max(context.toolbarFrame.maxY - windowOrigin.y + 1, 0)

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

    let debugContext =
      """
      appChromeState=\(chromeState.app.label)
      toolbarChromeState=\(chromeState.toolbar.label)
      sidebarFrame=\(NSStringFromRect(context.sidebarFrame))
      contentFrame=\(NSStringFromRect(context.contentFrame))
      toolbarFrame=\(NSStringFromRect(context.toolbarFrame))
      """

    return SplitBoundaryTintMeasurement(
      sidebarToolbar: sampleAverageColor(
        image: context.image,
        rect: scaledRect(sidebarToolbarRect, scaleX: context.scaleX, scaleY: context.scaleY)
      ),
      sidebarBelowToolbar: sampleAverageColor(
        image: context.image,
        rect: scaledRect(
          sidebarBelowToolbarRect,
          scaleX: context.scaleX,
          scaleY: context.scaleY
        )
      ),
      detailToolbar: sampleAverageColor(
        image: context.image,
        rect: scaledRect(detailToolbarRect, scaleX: context.scaleX, scaleY: context.scaleY)
      ),
      debugContext: debugContext
    )
  }

  fileprivate func sampleAverageColor(image: CGImage, rect: CGRect) -> ToolbarAverageColor {
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

  fileprivate func scaledRect(_ rect: CGRect, scaleX: CGFloat, scaleY: CGFloat) -> CGRect {
    CGRect(
      x: rect.minX * scaleX,
      y: rect.minY * scaleY,
      width: rect.width * scaleX,
      height: rect.height * scaleY
    )
  }
}
