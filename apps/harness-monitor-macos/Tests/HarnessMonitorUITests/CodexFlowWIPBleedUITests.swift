import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class CodexFlowWIPBleedUITests: HarnessMonitorUITestCase {
  func testCodexFlowWIPOverlayIsClippedToButtonBounds() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit"]
    )

    tapPreviewSession(in: app)

    let codexFlowButton = button(in: app, identifier: Accessibility.codexFlowButton)
    let agentTuiButton = button(in: app, identifier: Accessibility.agentTuiButton)
    let wipBadge = element(in: app, identifier: Accessibility.codexFlowWIPBadge)

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        codexFlowButton.exists
          && !codexFlowButton.frame.isEmpty
          && agentTuiButton.exists
          && !agentTuiButton.frame.isEmpty
          && wipBadge.exists
      }
    )
    XCTAssertFalse(codexFlowButton.isEnabled)

    let measurement = measureOverlayBleed(
      in: app,
      codexFlowButton: codexFlowButton,
      referenceButton: agentTuiButton
    )

    attachDiagnostic(measurement.debugDescription, named: "codex-flow-wip-bleed")
    attachWindowScreenshot(in: app, named: "codex-flow-wip-bleed")

    XCTAssertLessThan(
      measurement.topDistance,
      0.035,
      """
      Codex Flow blur still bleeds above the button bounds compared with the adjacent Agent TUI card. \
      \(measurement.debugDescription)
      """
    )
    XCTAssertLessThan(
      measurement.bottomDistance,
      0.035,
      """
      Codex Flow blur still bleeds below the button bounds compared with the adjacent Agent TUI card. \
      \(measurement.debugDescription)
      """
    )
  }

  private func measureOverlayBleed(
    in app: XCUIApplication,
    codexFlowButton: XCUIElement,
    referenceButton: XCUIElement
  ) -> CodexFlowOverlayBleedMeasurement {
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
      return .zero
    }

    let scaleX = CGFloat(cgImage.width) / window.frame.width
    let scaleY = CGFloat(cgImage.height) / window.frame.height
    let windowOrigin = window.frame.origin

    let codexTop = sampleAverageColor(
      image: cgImage,
      rect: scaledRect(
        comparisonRect(
          for: codexFlowButton.frame,
          windowOrigin: windowOrigin,
          edge: .top
        ),
        scaleX: scaleX,
        scaleY: scaleY
      )
    )
    let referenceTop = sampleAverageColor(
      image: cgImage,
      rect: scaledRect(
        comparisonRect(
          for: referenceButton.frame,
          windowOrigin: windowOrigin,
          edge: .top
        ),
        scaleX: scaleX,
        scaleY: scaleY
      )
    )
    let codexBottom = sampleAverageColor(
      image: cgImage,
      rect: scaledRect(
        comparisonRect(
          for: codexFlowButton.frame,
          windowOrigin: windowOrigin,
          edge: .bottom
        ),
        scaleX: scaleX,
        scaleY: scaleY
      )
    )
    let referenceBottom = sampleAverageColor(
      image: cgImage,
      rect: scaledRect(
        comparisonRect(
          for: referenceButton.frame,
          windowOrigin: windowOrigin,
          edge: .bottom
        ),
        scaleX: scaleX,
        scaleY: scaleY
      )
    )

    return CodexFlowOverlayBleedMeasurement(
      codexTop: codexTop,
      referenceTop: referenceTop,
      codexBottom: codexBottom,
      referenceBottom: referenceBottom
    )
  }

  private func comparisonRect(
    for buttonFrame: CGRect,
    windowOrigin: CGPoint,
    edge: VerticalEdge
  ) -> CGRect {
    let sampleWidth = min(buttonFrame.width * 0.28, 52)
    let sampleHeight: CGFloat = 6
    let sampleX = buttonFrame.midX - windowOrigin.x - (sampleWidth / 2)
    let sampleY =
      switch edge {
      case .top:
        buttonFrame.minY - windowOrigin.y - sampleHeight - 3
      case .bottom:
        buttonFrame.maxY - windowOrigin.y + 3
      }

    return CGRect(
      x: max(sampleX, 0),
      y: max(sampleY, 0),
      width: max(sampleWidth, 1),
      height: sampleHeight
    )
  }

  private func sampleAverageColor(image: CGImage, rect: CGRect) -> RGBColor {
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

    return RGBColor(
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
}

private enum VerticalEdge {
  case top
  case bottom
}

private struct CodexFlowOverlayBleedMeasurement {
  let codexTop: RGBColor
  let referenceTop: RGBColor
  let codexBottom: RGBColor
  let referenceBottom: RGBColor

  static let zero = Self(
    codexTop: .zero,
    referenceTop: .zero,
    codexBottom: .zero,
    referenceBottom: .zero
  )

  var topDistance: Double {
    codexTop.distance(to: referenceTop)
  }

  var bottomDistance: Double {
    codexBottom.distance(to: referenceBottom)
  }

  var debugDescription: String {
    """
    topDistance=\(String(format: "%.4f", topDistance)) \
    bottomDistance=\(String(format: "%.4f", bottomDistance)) \
    codexTop[\(codexTop.debugDescription)] \
    referenceTop[\(referenceTop.debugDescription)] \
    codexBottom[\(codexBottom.debugDescription)] \
    referenceBottom[\(referenceBottom.debugDescription)]
    """
  }
}

private extension RGBColor {
  func distance(to other: Self) -> Double {
    abs(red - other.red) + abs(green - other.green) + abs(blue - other.blue)
  }

  var debugDescription: String {
    String(format: "r=%.4f g=%.4f b=%.4f", red, green, blue)
  }
}

private extension HarnessMonitorUITestCase {
  func attachDiagnostic(_ text: String, named name: String) {
    let attachment = XCTAttachment(string: text)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
