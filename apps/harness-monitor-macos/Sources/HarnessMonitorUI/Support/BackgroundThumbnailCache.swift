import AppKit
import HarnessMonitorKit
import ImageIO
import os

public actor BackgroundThumbnailCache {
  public static let shared = BackgroundThumbnailCache()

  private let cacheDirectory: URL
  private let maxPixelSize: Int
  private var memoryCache: [String: CGImage] = [:]

  private static let allowedPathPrefixes = ["/System/Library/", "/Library/"]
  private static let allowedExtensions: Set<String> = ["heic", "jpg", "jpeg", "png", "tiff"]
  private static let maxFileSize: Int64 = 200 * 1024 * 1024

  public init(
    cacheDirectory: URL = HarnessMonitorPaths.thumbnailCacheRoot(),
    maxPixelSize: Int = 512
  ) {
    self.cacheDirectory = cacheDirectory
    self.maxPixelSize = maxPixelSize
  }

  // MARK: - Public

  public func thumbnail(for selection: HarnessMonitorBackgroundSelection) -> CGImage? {
    let key = cacheKey(for: selection)

    if let cached = memoryCache[key] {
      return cached
    }

    switch selection.source {
    case .bundled(let image):
      return loadBundledThumbnail(key: key, image: image)
    case .system(let wallpaper):
      return loadSystemThumbnail(key: key, wallpaper: wallpaper)
    }
  }

  public func fullImage(for selection: HarnessMonitorBackgroundSelection) -> CGImage? {
    let key = "full:\(cacheKey(for: selection))"

    if let cached = memoryCache[key] {
      return cached
    }

    switch selection.source {
    case .bundled(let image):
      return loadBundledFullImage(key: key, image: image)
    case .system(let wallpaper):
      return loadSystemFullImage(key: key, wallpaper: wallpaper)
    }
  }

  public func prefetch(_ selections: [HarnessMonitorBackgroundSelection]) {
    for selection in selections {
      if Task.isCancelled { return }
      _ = thumbnail(for: selection)
    }
  }

  // MARK: - Bundled thumbnails

  private func loadBundledThumbnail(
    key: String,
    image: HarnessMonitorBackgroundImage
  ) -> CGImage? {
    if let diskImage = loadFromDiskCache(key: key, expectedMtime: nil) {
      memoryCache[key] = diskImage
      return diskImage
    }

    guard let nsImage = HarnessMonitorUIAssets.bundle.image(forResource: image.assetName) else {
      HarnessMonitorLogger.thumbnail.warning("Bundled image not found: \(image.assetName)")
      return nil
    }

    guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      HarnessMonitorLogger.thumbnail.warning("Failed to get CGImage from bundled: \(image.assetName)")
      return nil
    }

    guard let thumbnail = downsample(cgImage: cgImage) else {
      HarnessMonitorLogger.thumbnail.warning("Failed to downsample bundled: \(image.assetName)")
      return nil
    }

    saveToDiskCache(image: thumbnail, key: key, sourceMtime: nil)
    memoryCache[key] = thumbnail
    return thumbnail
  }

  private func loadBundledFullImage(
    key: String,
    image: HarnessMonitorBackgroundImage
  ) -> CGImage? {
    guard let nsImage = HarnessMonitorUIAssets.bundle.image(forResource: image.assetName) else {
      return nil
    }

    guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      return nil
    }

    memoryCache[key] = cgImage
    return cgImage
  }

  // MARK: - System thumbnails

  private func loadSystemThumbnail(
    key: String,
    wallpaper: HarnessMonitorSystemWallpaper
  ) -> CGImage? {
    guard validateSourcePath(wallpaper.imagePath) else {
      return nil
    }

    let sourceMtime = fileMtime(at: wallpaper.imagePath)

    if let diskImage = loadFromDiskCache(key: key, expectedMtime: sourceMtime) {
      memoryCache[key] = diskImage
      return diskImage
    }

    guard let thumbnail = downsampleFile(at: wallpaper.imagePath) else {
      HarnessMonitorLogger.thumbnail.warning("Failed to generate thumbnail: \(wallpaper.imagePath)")
      return nil
    }

    saveToDiskCache(image: thumbnail, key: key, sourceMtime: sourceMtime)
    memoryCache[key] = thumbnail
    return thumbnail
  }

  private func loadSystemFullImage(
    key: String,
    wallpaper: HarnessMonitorSystemWallpaper
  ) -> CGImage? {
    guard validateSourcePath(wallpaper.imagePath) else {
      return nil
    }

    let url = URL(fileURLWithPath: wallpaper.imagePath)
    let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]

    guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
      return nil
    }

    guard CGImageSourceGetStatus(source) == .statusComplete,
          CGImageSourceGetCount(source) > 0
    else {
      return nil
    }

    let imageOptions: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]

    guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, imageOptions as CFDictionary) else {
      return nil
    }

    memoryCache[key] = cgImage
    return cgImage
  }

  // MARK: - Security validation

  private func validateSourcePath(_ path: String) -> Bool {
    let resolvedPath = URL(fileURLWithPath: path).standardized.path

    let hasAllowedPrefix = Self.allowedPathPrefixes.contains { resolvedPath.hasPrefix($0) }
    guard hasAllowedPrefix else {
      HarnessMonitorLogger.thumbnail.warning("Path outside allowed directories: \(resolvedPath)")
      return false
    }

    let pathExtension = (resolvedPath as NSString).pathExtension.lowercased()
    guard Self.allowedExtensions.contains(pathExtension) else {
      HarnessMonitorLogger.thumbnail.warning("Disallowed extension: \(pathExtension)")
      return false
    }

    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedPath),
      let fileType = attributes[.type] as? FileAttributeType,
      fileType == .typeRegular
    else {
      HarnessMonitorLogger.thumbnail.warning("Not a regular file: \(resolvedPath)")
      return false
    }

    if let fileSize = attributes[.size] as? Int64, fileSize > Self.maxFileSize {
      HarnessMonitorLogger.thumbnail.warning(
        "File too large (\(fileSize) bytes): \(resolvedPath)"
      )
      return false
    }

    return true
  }

  // MARK: - Thumbnail generation

  private func downsampleFile(at path: String) -> CGImage? {
    let url = URL(fileURLWithPath: path)
    let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]

    guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
      return nil
    }

    guard CGImageSourceGetStatus(source) == .statusComplete,
          CGImageSourceGetCount(source) > 0
    else {
      HarnessMonitorLogger.thumbnail.warning("Invalid image source: \(path)")
      return nil
    }

    let thumbnailOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
    ]

    return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
  }

  private func downsample(cgImage: CGImage) -> CGImage? {
    let data = NSMutableData()

    guard let destination = CGImageDestinationCreateWithData(
      data as CFMutableData, "public.jpeg" as CFString, 1, nil
    ) else {
      return nil
    }

    CGImageDestinationAddImage(destination, cgImage, nil)

    guard CGImageDestinationFinalize(destination) else {
      return nil
    }

    let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]

    guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
      return nil
    }

    let thumbnailOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
    ]

    return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
  }

  // MARK: - Disk cache

  private func diskCachePath(key: String, extension ext: String) -> URL {
    cacheDirectory.appendingPathComponent("\(key).\(ext)")
  }

  private func loadFromDiskCache(key: String, expectedMtime: TimeInterval?) -> CGImage? {
    let jpegURL = diskCachePath(key: key, extension: "jpg")
    let metaURL = diskCachePath(key: key, extension: "meta")

    guard FileManager.default.fileExists(atPath: jpegURL.path),
          FileManager.default.fileExists(atPath: metaURL.path)
    else {
      return nil
    }

    guard let metaString = try? String(contentsOf: metaURL, encoding: .utf8).trimmingCharacters(
      in: .whitespacesAndNewlines
    ) else {
      return nil
    }

    if let expectedMtime {
      guard let storedMtime = TimeInterval(metaString),
            abs(storedMtime - expectedMtime) < 0.001
      else {
        return nil
      }
    } else {
      guard metaString == "bundled" else {
        return nil
      }
    }

    let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]

    guard let source = CGImageSourceCreateWithURL(
      jpegURL as CFURL, sourceOptions as CFDictionary
    ) else {
      return nil
    }

    let imageOptions: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
    return CGImageSourceCreateImageAtIndex(source, 0, imageOptions as CFDictionary)
  }

  private func saveToDiskCache(image: CGImage, key: String, sourceMtime: TimeInterval?) {
    do {
      try FileManager.default.createDirectory(
        at: cacheDirectory, withIntermediateDirectories: true
      )
    } catch {
      HarnessMonitorLogger.thumbnail.warning("Failed to create cache directory: \(error)")
      return
    }

    let jpegURL = diskCachePath(key: key, extension: "jpg")
    let metaURL = diskCachePath(key: key, extension: "meta")

    let rep = NSBitmapImageRep(cgImage: image)
    guard let jpegData = rep.representation(
      using: .jpeg, properties: [.compressionFactor: 0.85]
    ) else {
      return
    }

    let tmpJPEG = cacheDirectory.appendingPathComponent(".\(key).jpg.tmp")
    let tmpMeta = cacheDirectory.appendingPathComponent(".\(key).meta.tmp")

    do {
      try jpegData.write(to: tmpJPEG, options: .atomic)
      _ = try FileManager.default.replaceItemAt(jpegURL, withItemAt: tmpJPEG)
    } catch {
      HarnessMonitorLogger.thumbnail.warning("Failed to write thumbnail: \(error)")
      try? FileManager.default.removeItem(at: tmpJPEG)
      return
    }

    let metaContent = sourceMtime.map { String($0) } ?? "bundled"
    do {
      try metaContent.write(to: tmpMeta, atomically: true, encoding: .utf8)
      _ = try FileManager.default.replaceItemAt(metaURL, withItemAt: tmpMeta)
    } catch {
      HarnessMonitorLogger.thumbnail.warning("Failed to write meta: \(error)")
      try? FileManager.default.removeItem(at: tmpMeta)
    }
  }

  // MARK: - Helpers

  private func cacheKey(for selection: HarnessMonitorBackgroundSelection) -> String {
    switch selection.source {
    case .bundled(let image): image.rawValue
    case .system(let wallpaper): wallpaper.id
    }
  }

  private func fileMtime(at path: String) -> TimeInterval? {
    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: path),
      let date = attributes[.modificationDate] as? Date
    else {
      return nil
    }
    return date.timeIntervalSince1970
  }
}

