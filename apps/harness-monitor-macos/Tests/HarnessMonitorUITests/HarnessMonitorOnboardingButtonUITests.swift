import AppKit
import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorOnboardingButtonUITests: HarnessMonitorUITestCase {

  func testCaptureOnboardingAndFilterChipScreenshots() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard"]
    )

    let startButton = button(in: app, identifier: Accessibility.onboardingStartButton)
    XCTAssertTrue(startButton.waitForExistence(timeout: Self.uiTimeout), "Start Daemon not found")

    let installButton = button(in: app, identifier: Accessibility.onboardingInstallButton)
    XCTAssertTrue(installButton.waitForExistence(timeout: Self.uiTimeout), "Install Launch Agent not found")

    let refreshButton = button(in: app, identifier: Accessibility.onboardingRefreshButton)
    XCTAssertTrue(refreshButton.waitForExistence(timeout: Self.uiTimeout), "Refresh Index not found")

    let allFilter = button(in: app, identifier: Accessibility.allFilterButton)
    XCTAssertTrue(allFilter.waitForExistence(timeout: Self.uiTimeout), "All filter chip not found")

    let activeFilter = button(in: app, identifier: Accessibility.activeFilterButton)
    XCTAssertTrue(activeFilter.waitForExistence(timeout: Self.uiTimeout), "Active filter chip not found")

    let elements: [(String, XCUIElement)] = [
      ("onboarding-start-daemon", startButton),
      ("onboarding-install-launch-agent", installButton),
      ("onboarding-refresh-index", refreshButton),
      ("filter-chip-all-unselected", allFilter),
      ("filter-chip-active-selected", activeFilter),
    ]

    for (name, element) in elements {
      let screenshot = element.screenshot()
      let attachment = XCTAttachment(screenshot: screenshot)
      attachment.name = name
      attachment.lifetime = .keepAlways
      add(attachment)

      let bg = darkestColor(of: element)
      let text = textColor(of: element)
      let bgSpread = channelSpread(bg)
      let textSpread = channelSpread(text)

      let b64 = screenshotBase64(screenshot)

      print(
        "BUTTON_DATA[\(name)] "
          + "bg_r=\(String(format: "%.4f", bg.red)) bg_g=\(String(format: "%.4f", bg.green)) bg_b=\(String(format: "%.4f", bg.blue)) "
          + "bgSpread=\(String(format: "%.4f", bgSpread)) "
          + "text_r=\(String(format: "%.4f", text.red)) text_g=\(String(format: "%.4f", text.green)) text_b=\(String(format: "%.4f", text.blue)) "
          + "textSpread=\(String(format: "%.4f", textSpread)) "
          + "img=\(b64)"
      )
    }

    // Regression guard: Refresh Index background must be neutral (no color tint)
    let refreshBg = darkestColor(of: refreshButton)
    XCTAssertLessThan(
      channelSpread(refreshBg), 0.04,
      "Refresh button background has a color tint: spread=\(channelSpread(refreshBg))"
    )

    // Regression guard: Refresh Index text must be neutral (no accent tint)
    let refreshText = textColor(of: refreshButton)
    XCTAssertLessThan(
      channelSpread(refreshText), 0.08,
      "Refresh button text has a color tint: spread=\(channelSpread(refreshText))"
    )
  }

  /// Sample the top 5% brightest pixels in the center strip to isolate
  /// the rendered text color. A tight percentile avoids background dilution
  /// on small elements like filter chips where text is a small fraction.
  private func textColor(of element: XCUIElement) -> RGBColor {
    let screenshot = element.screenshot()
    guard let cgImage = screenshot.image.cgImage(
      forProposedRect: nil,
      context: nil,
      hints: nil
    ) else {
      return RGBColor(red: 0, green: 0, blue: 0)
    }

    let width = cgImage.width
    let height = cgImage.height
    guard width > 4, height > 4 else {
      return RGBColor(red: 0, green: 0, blue: 0)
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
      return RGBColor(red: 0, green: 0, blue: 0)
    }

    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    struct PixelSample {
      let red: Double
      let green: Double
      let blue: Double
      let luminance: Double
    }

    let startRow = height / 4
    let endRow = height * 3 / 4
    let edgeSkip = 4
    var samples: [PixelSample] = []

    for row in stride(from: startRow, to: endRow, by: 1) {
      for col in stride(from: edgeSkip, to: width - edgeSkip, by: 2) {
        let offset = row * bytesPerRow + col * bytesPerPixel
        let red = Double(pixels[offset]) / 255.0
        let green = Double(pixels[offset + 1]) / 255.0
        let blue = Double(pixels[offset + 2]) / 255.0
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        samples.append(PixelSample(red: red, green: green, blue: blue, luminance: luminance))
      }
    }

    guard !samples.isEmpty else {
      return RGBColor(red: 0, green: 0, blue: 0)
    }

    let sorted = samples.sorted { $0.luminance > $1.luminance }
    let topCount = max(sorted.count / 20, 1)
    let topSlice = sorted.prefix(topCount)

    let avgRed = topSlice.reduce(0.0) { $0 + $1.red } / Double(topCount)
    let avgGreen = topSlice.reduce(0.0) { $0 + $1.green } / Double(topCount)
    let avgBlue = topSlice.reduce(0.0) { $0 + $1.blue } / Double(topCount)

    return RGBColor(red: avgRed, green: avgGreen, blue: avgBlue)
  }

  /// Sample the darkest 30% of pixels to isolate the background color,
  /// excluding text pixels which are brighter.
  private func darkestColor(of element: XCUIElement) -> RGBColor {
    let screenshot = element.screenshot()
    guard let cgImage = screenshot.image.cgImage(
      forProposedRect: nil,
      context: nil,
      hints: nil
    ) else {
      return RGBColor(red: 0, green: 0, blue: 0)
    }

    let width = cgImage.width
    let height = cgImage.height
    guard width > 4, height > 4 else {
      return RGBColor(red: 0, green: 0, blue: 0)
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
      return RGBColor(red: 0, green: 0, blue: 0)
    }

    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    struct PixelSample {
      let red: Double
      let green: Double
      let blue: Double
      let luminance: Double
    }

    let edgeSkip = 2
    var samples: [PixelSample] = []
    for row in stride(from: edgeSkip, to: height - edgeSkip, by: 1) {
      for col in stride(from: edgeSkip, to: width - edgeSkip, by: 2) {
        let offset = row * bytesPerRow + col * bytesPerPixel
        let red = Double(pixels[offset]) / 255.0
        let green = Double(pixels[offset + 1]) / 255.0
        let blue = Double(pixels[offset + 2]) / 255.0
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        samples.append(PixelSample(red: red, green: green, blue: blue, luminance: luminance))
      }
    }

    guard !samples.isEmpty else {
      return RGBColor(red: 0, green: 0, blue: 0)
    }

    // Sort by luminance ascending, take bottom 30% as background pixels.
    let sorted = samples.sorted { $0.luminance < $1.luminance }
    let bottomCount = max(sorted.count * 3 / 10, 1)
    let bottomSlice = sorted.prefix(bottomCount)

    let avgRed = bottomSlice.reduce(0.0) { $0 + $1.red } / Double(bottomCount)
    let avgGreen = bottomSlice.reduce(0.0) { $0 + $1.green } / Double(bottomCount)
    let avgBlue = bottomSlice.reduce(0.0) { $0 + $1.blue } / Double(bottomCount)

    return RGBColor(red: avgRed, green: avgGreen, blue: avgBlue)
  }

  private func screenshotBase64(_ screenshot: XCUIScreenshot) -> String {
    guard let cgImage = screenshot.image.cgImage(
      forProposedRect: nil,
      context: nil,
      hints: nil
    ) else { return "" }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    guard let data = rep.representation(using: .png, properties: [:]) else { return "" }
    return data.base64EncodedString()
  }

  private func channelSpread(_ color: RGBColor) -> Double {
    let maxChannel = max(color.red, max(color.green, color.blue))
    let minChannel = min(color.red, min(color.green, color.blue))
    return maxChannel - minChannel
  }
}
