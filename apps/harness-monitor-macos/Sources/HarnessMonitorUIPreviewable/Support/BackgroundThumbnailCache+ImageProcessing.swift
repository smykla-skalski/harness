import AppKit
import HarnessMonitorKit
import ImageIO

extension BackgroundThumbnailCache {
  nonisolated func thumbnailMaxPixelSize(for source: CGImageSource) -> Int? {
    guard
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?,
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int
    else {
      return nil
    }

    let sourceMaxPixelSize = max(width, height)
    guard sourceMaxPixelSize > 0 else { return nil }

    return min(maxPixelSize, sourceMaxPixelSize)
  }

  nonisolated func opaqueRGBImage(from image: CGImage, maxPixelSize: Int?) -> CGImage? {
    let targetSize = targetPixelSize(for: image, maxPixelSize: maxPixelSize)
    guard targetSize.width > 0, targetSize.height > 0 else { return nil }

    let colorSpace =
      image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)
      ?? CGColorSpaceCreateDeviceRGB()
    guard
      let context = CGContext(
        data: nil,
        width: targetSize.width,
        height: targetSize.height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      )
    else {
      return nil
    }

    let targetRect = CGRect(
      x: 0,
      y: 0,
      width: CGFloat(targetSize.width),
      height: CGFloat(targetSize.height)
    )
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    context.fill(targetRect)
    context.interpolationQuality = .high
    context.draw(image, in: targetRect)
    return context.makeImage()
  }

  nonisolated func targetPixelSize(
    for image: CGImage,
    maxPixelSize: Int?
  ) -> (width: Int, height: Int) {
    let sourceSize = (width: image.width, height: image.height)
    guard let maxPixelSize, maxPixelSize > 0 else { return sourceSize }

    let sourceMaxPixelSize = max(image.width, image.height)
    guard sourceMaxPixelSize > maxPixelSize else { return sourceSize }

    let scale = CGFloat(maxPixelSize) / CGFloat(sourceMaxPixelSize)
    return (
      width: max(1, Int((CGFloat(image.width) * scale).rounded())),
      height: max(1, Int((CGFloat(image.height) * scale).rounded()))
    )
  }

  nonisolated func cacheKey(for selection: HarnessMonitorBackgroundSelection) -> String {
    switch selection.source {
    case .bundled(let image): image.rawValue
    case .system(let wallpaper): wallpaper.id
    }
  }

  nonisolated func fileMtime(at path: String) -> TimeInterval? {
    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: path),
      let date = attributes[.modificationDate] as? Date
    else {
      return nil
    }
    return date.timeIntervalSince1970
  }
}
