import AppKit
import Foundation
import ImageIO
import XCTest

@testable import HarnessMonitorKit

final class ReviewAvatarCacheTests: XCTestCase {
  func testDownsampleReturnsBitmapAtMostTargetPixelSize() throws {
    let original = try Self.makeSolidColorPNG(size: NSSize(width: 256, height: 256))
    let image = try XCTUnwrap(
      ReviewAvatarCache.downsample(data: original, targetPixel: 64)
    )
    XCTAssertLessThanOrEqual(image.size.width, 64)
    XCTAssertLessThanOrEqual(image.size.height, 64)
  }

  func testDownsampleClampsToFloorWhenTargetSmall() throws {
    let original = try Self.makeSolidColorPNG(size: NSSize(width: 256, height: 256))
    let image = try XCTUnwrap(
      ReviewAvatarCache.downsample(data: original, targetPixel: 8)
    )
    XCTAssertGreaterThanOrEqual(image.size.width, 32)
  }

  func testDownsampleReturnsNilForInvalidData() {
    let result = ReviewAvatarCache.downsample(
      data: Data([0x00, 0x01, 0x02]),
      targetPixel: 64
    )
    XCTAssertNil(result)
  }

  private static func makeSolidColorPNG(size: NSSize) throws -> Data {
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: Int(size.width),
      pixelsHigh: Int(size.height),
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 32
    )
    let unwrapped = try XCTUnwrap(bitmap)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: unwrapped)
    NSColor.systemBlue.setFill()
    NSRect(origin: .zero, size: size).fill()
    NSGraphicsContext.restoreGraphicsState()
    return try XCTUnwrap(unwrapped.representation(using: .png, properties: [:]))
  }
}
