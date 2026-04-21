import AppKit
import CoreGraphics
import Foundation
import ImageIO

public protocol HarnessMonitorNotificationAssetWriting: Sendable {
  @MainActor
  func sampleImageURL() throws -> URL
}

public struct HarnessMonitorNotificationAssetWriter: HarnessMonitorNotificationAssetWriting {
  private static let sampleImageName = "harness-monitor-notification-sample.png"

  private let environment: HarnessMonitorEnvironment

  public init(environment: HarnessMonitorEnvironment = .current) {
    self.environment = environment
  }

  public func sampleImageURL() throws -> URL {
    let directory = HarnessMonitorPaths.notificationCacheRoot(using: environment)
    let legacyDirectory = HarnessMonitorPaths.harnessRoot(using: environment)
      .appendingPathComponent("cache", isDirectory: true)
      .appendingPathComponent("notifications", isDirectory: true)
    let fileManager = FileManager.default
    try HarnessMonitorPaths.prepareGeneratedCacheDirectory(
      directory,
      cleaningLegacyDirectories: [legacyDirectory],
      fileManager: fileManager
    )

    let url = directory.appendingPathComponent(Self.sampleImageName)
    if !fileManager.fileExists(atPath: url.path) || Self.cachedSampleImageRequiresRewrite(at: url) {
      try Self.makeSampleImageData().write(to: url, options: .atomic)
    }
    return url
  }

  private static func cachedSampleImageRequiresRewrite(at url: URL) -> Bool {
    guard
      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?
    else {
      return true
    }

    return properties[kCGImagePropertyHasAlpha] as? Bool == true
  }

  private static func makeSampleImageData() throws -> Data {
    let width = 640
    let height = 360
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      )
    else {
      throw HarnessMonitorNotificationError.assetGenerationFailed("sample PNG")
    }

    context.setFillColor(CGColor(red: 0.08, green: 0.1, blue: 0.11, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    let tilePath = CGPath(
      roundedRect: CGRect(x: 56, y: 64, width: 180, height: 180),
      cornerWidth: 18,
      cornerHeight: 18,
      transform: nil
    )
    context.addPath(tilePath)
    context.setFillColor(CGColor(red: 0.0, green: 0.72, blue: 0.88, alpha: 1))
    context.fillPath()

    context.setFillColor(CGColor(red: 0.96, green: 0.82, blue: 0.2, alpha: 1))
    context.fillEllipse(in: CGRect(x: 360, y: 126, width: 136, height: 136))

    context.setStrokeColor(CGColor(red: 0.85, green: 0.92, blue: 0.88, alpha: 1))
    context.setLineWidth(16)
    context.setLineCap(.round)
    context.beginPath()
    context.move(to: CGPoint(x: 108, y: 164))
    context.addLine(to: CGPoint(x: 172, y: 116))
    context.addLine(to: CGPoint(x: 252, y: 244))
    context.addLine(to: CGPoint(x: 340, y: 170))
    context.addLine(to: CGPoint(x: 444, y: 222))
    context.addLine(to: CGPoint(x: 548, y: 118))
    context.strokePath()

    guard let image = context.makeImage() else {
      throw HarnessMonitorNotificationError.assetGenerationFailed("sample PNG")
    }
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let data = bitmap.representation(using: .png, properties: [:])
    else {
      throw HarnessMonitorNotificationError.assetGenerationFailed("sample PNG")
    }
    return data
  }

}
