import AppKit
import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class DashboardDebuggingOCRUITests: HarnessMonitorUITestCase {
  func testSystemScreenshotFolderIngestsNewScreenshotAndPreviewShowsScannedText() throws {
    let screenshotFolder = FileManager.default.temporaryDirectory
      .appendingPathComponent("HarnessMonitorOCRUITests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: screenshotFolder,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: screenshotFolder) }

    let app = launch(
      mode: "preview",
      additionalEnvironment: [
        "HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard",
        "HARNESS_MONITOR_DEBUGGING_OCR_SCREENSHOT_FOLDER": screenshotFolder.path,
      ]
    )
    openDebuggingRoute(in: app)

    let watcherStatus = element(
      in: app,
      identifier: Accessibility.dashboardDebuggingOCRShotStatus
    )
    XCTAssertTrue(waitForElement(in: app, watcherStatus, timeout: Self.actionTimeout))
    XCTAssertTrue(
      waitUntil(in: app, timeout: Self.actionTimeout) {
        (watcherStatus.value as? String)?.contains("Watching") == true
          || watcherStatus.label.contains("Watching")
      },
      "Screenshot watcher should be active before creating a test screenshot"
    )

    let screenshotURL =
      screenshotFolder
      .appendingPathComponent("Screenshot 2026-05-26 at 17.30.00.png")
    try makeScreenshotPNG(text: "OCR PREVIEW TEXT").write(to: screenshotURL)

    let resultList = element(in: app, identifier: Accessibility.dashboardDebuggingOCRResultList)
    XCTAssertTrue(
      waitForElement(in: app, resultList, timeout: 20),
      "A new screenshot should be ingested into the OCR result list"
    )
    XCTAssertTrue(
      waitUntil(in: app, timeout: 20) {
        app.staticTexts["Text found"].exists
      },
      "Vision should recognize text in the generated screenshot"
    )
    attachWindowScreenshot(in: app, named: "debugging-ocr-screenshot-ingested")

    let previewButton = button(
      in: app,
      identifier: Accessibility.dashboardDebuggingOCRResultPreviewButton
    )
    XCTAssertTrue(waitForElement(in: app, previewButton, timeout: Self.actionTimeout))
    XCTAssertTrue(tapElementReliably(in: app, element: previewButton))

    let previewText = element(
      in: app,
      identifier: Accessibility.dashboardDebuggingOCRPreviewText
    )
    XCTAssertTrue(
      waitForElement(in: app, previewText, timeout: Self.actionTimeout),
      "Preview sheet should show the scanned text below the image"
    )
    attachWindowScreenshot(in: app, named: "debugging-ocr-preview-scanned-text")
  }

  private func openDebuggingRoute(in app: XCUIApplication) {
    let debuggingRoute = element(
      in: app,
      identifier: Accessibility.dashboardWindowRoute("debugging")
    )
    XCTAssertTrue(waitForElement(in: app, debuggingRoute, timeout: Self.actionTimeout))
    XCTAssertTrue(tapElementReliably(in: app, element: debuggingRoute))
    let debuggingRoot = element(in: app, identifier: Accessibility.dashboardDebuggingRoot)
    XCTAssertTrue(waitForElement(in: app, debuggingRoot, timeout: Self.actionTimeout))
  }

  private func makeScreenshotPNG(text: String) throws -> Data {
    let size = NSSize(width: 1_000, height: 320)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedSystemFont(ofSize: 64, weight: .bold),
      .foregroundColor: NSColor.black,
    ]
    NSString(string: text).draw(
      in: NSRect(x: 48, y: 120, width: 904, height: 90),
      withAttributes: attributes
    )
    image.unlockFocus()
    let tiffData = try XCTUnwrap(image.tiffRepresentation)
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiffData))
    return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
  }
}
