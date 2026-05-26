import AppKit
import CryptoKit
import Foundation

enum DashboardOCRImageFingerprint {
  static func make(data: Data) -> String {
    if let image = NSImage(data: data), let pixelHash = makePixelHash(image: image) {
      return pixelHash
    }
    return "data:\(hexDigest(for: data))"
  }

  static func make(image: NSImage) -> String {
    makePixelHash(image: image) ?? "image:\(UUID().uuidString)"
  }

  private static func makePixelHash(image: NSImage) -> String? {
    guard let cgImage = image.dashboardOCRCGImage else {
      return nil
    }
    let width = cgImage.width
    let height = cgImage.height
    let bytesPerRow = max(1, width) * 4
    var pixels = Data(count: max(1, height) * bytesPerRow)
    let didRender = pixels.withUnsafeMutableBytes { buffer in
      guard let baseAddress = buffer.baseAddress else {
        return false
      }
      let context = CGContext(
        data: baseAddress,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
      context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
      return context != nil
    }
    guard didRender else {
      return nil
    }
    return "pixels:\(width)x\(height):\(hexDigest(for: pixels))"
  }

  private static func hexDigest(for data: Data) -> String {
    SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
  }
}
