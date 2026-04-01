import AppKit
import XCTest

struct RGBColor {
  let red: Double
  let green: Double
  let blue: Double
}

struct LuminanceStats {
  let min: Double
  let max: Double
  let mean: Double
  let stddev: Double
  let count: Int
}

enum SampleRegion {
  case top
  case center
}

extension HarnessUITestCase {

  /// Capture the element's screenshot and downscale it to a single pixel
  /// using CGContext. Core Graphics averages all pixels during the draw,
  /// giving the true average RGBA of the rendered appearance.
  /// Reference: https://medium.com/@mallabhyas/how-to-compute-the-average-color-of-an-image-using-cgcontext-in-swift-f774981a224e
  func averageColor(of element: XCUIElement) -> RGBColor {
    let screenshot = element.screenshot()
    guard let cgImage = screenshot.image.cgImage(
      forProposedRect: nil,
      context: nil,
      hints: nil
    ) else {
      return RGBColor(red: 0, green: 0, blue: 0)
    }

    var pixel = [UInt8](repeating: 0, count: 4)

    guard let context = CGContext(
      data: &pixel,
      width: 1,
      height: 1,
      bitsPerComponent: 8,
      bytesPerRow: 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      return RGBColor(red: 0, green: 0, blue: 0)
    }

    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))

    let alpha = Double(pixel[3]) / 255.0
    guard alpha > 0.001 else {
      return RGBColor(red: 0, green: 0, blue: 0)
    }

    return RGBColor(
      red: Double(pixel[0]) / 255.0 / alpha,
      green: Double(pixel[1]) / 255.0 / alpha,
      blue: Double(pixel[2]) / 255.0 / alpha
    )
  }

  func edgeLuminance(
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

    let stripHeight: Int
    let startRow: Int
    switch region {
    case .top:
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

  func luminanceStats(of element: XCUIElement) -> LuminanceStats {
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
