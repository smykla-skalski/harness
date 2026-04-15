import AppKit
import HarnessMonitorKit
import ImageIO
import os

private let log = Logger(subsystem: "io.harnessmonitor", category: "thumbnail")

public actor BackgroundThumbnailCache {
  public static let shared = BackgroundThumbnailCache()

  let cacheDirectory: URL
  let maxPixelSize: Int
  let thumbnailMemoryLimit: Int
  let fullImageMemoryLimit: Int
  var thumbnailMemoryCache: [String: CGImage] = [:]
  var fullImageMemoryCache: [String: CGImage] = [:]
  private var thumbnailAccessOrder: [String] = []
  private var fullImageAccessOrder: [String] = []

  static let allowedPathPrefixes = ["/System/Library/", "/Library/"]
  static let allowedExtensions: Set<String> = ["heic", "jpg", "jpeg", "png", "tiff"]
  static let maxFileSize: Int64 = 200 * 1024 * 1024

  public init(
    cacheDirectory: URL = HarnessMonitorPaths.thumbnailCacheRoot(),
    maxPixelSize: Int = 512,
    thumbnailMemoryLimit: Int = 24,
    fullImageMemoryLimit: Int = 1
  ) {
    self.cacheDirectory = cacheDirectory
    self.maxPixelSize = maxPixelSize
    self.thumbnailMemoryLimit = max(0, thumbnailMemoryLimit)
    self.fullImageMemoryLimit = max(0, fullImageMemoryLimit)
  }

  // MARK: - Public

  public func thumbnail(for selection: HarnessMonitorBackgroundSelection) -> CGImage? {
    let key = cacheKey(for: selection)

    if let cached = cachedMemoryImage(for: key, kind: .thumbnail) {
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

    if let cached = cachedMemoryImage(for: key, kind: .fullImage) {
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
      cacheMemoryImage(diskImage, for: key, kind: .thumbnail)
      return diskImage
    }

    guard let nsImage = HarnessMonitorUIAssets.bundle.image(forResource: image.assetName) else {
      log.warning("Bundled image not found: \(image.assetName)")
      return nil
    }

    guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      log.warning("Failed to get CGImage from bundled: \(image.assetName)")
      return nil
    }

    guard let thumbnail = downsample(cgImage: cgImage) else {
      log.warning("Failed to downsample bundled: \(image.assetName)")
      return nil
    }

    saveToDiskCache(image: thumbnail, key: key, sourceMtime: nil)
    cacheMemoryImage(thumbnail, for: key, kind: .thumbnail)
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

    cacheMemoryImage(cgImage, for: key, kind: .fullImage)
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
      cacheMemoryImage(diskImage, for: key, kind: .thumbnail)
      return diskImage
    }

    guard let thumbnail = downsampleFile(at: wallpaper.imagePath) else {
      log.warning("Failed to generate thumbnail: \(wallpaper.imagePath)")
      return nil
    }

    saveToDiskCache(image: thumbnail, key: key, sourceMtime: sourceMtime)
    cacheMemoryImage(thumbnail, for: key, kind: .thumbnail)
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

    guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary)
    else {
      return nil
    }

    guard CGImageSourceGetStatus(source) == .statusComplete,
      CGImageSourceGetCount(source) > 0
    else {
      return nil
    }

    let imageOptions: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]

    guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, imageOptions as CFDictionary)
    else {
      return nil
    }

    cacheMemoryImage(cgImage, for: key, kind: .fullImage)
    return cgImage
  }

  // MARK: - Security validation

  private func validateSourcePath(_ path: String) -> Bool {
    let resolvedPath = URL(fileURLWithPath: path).standardized.path

    let hasAllowedPrefix = Self.allowedPathPrefixes.contains { resolvedPath.hasPrefix($0) }
    guard hasAllowedPrefix else {
      log.warning("Path outside allowed directories: \(resolvedPath)")
      return false
    }

    let pathExtension = (resolvedPath as NSString).pathExtension.lowercased()
    guard Self.allowedExtensions.contains(pathExtension) else {
      log.warning("Disallowed extension: \(pathExtension)")
      return false
    }

    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedPath),
      let fileType = attributes[.type] as? FileAttributeType,
      fileType == .typeRegular
    else {
      log.warning("Not a regular file: \(resolvedPath)")
      return false
    }

    if let fileSize = attributes[.size] as? Int64, fileSize > Self.maxFileSize {
      log.warning(
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

    guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary)
    else {
      return nil
    }

    guard CGImageSourceGetStatus(source) == .statusComplete,
      CGImageSourceGetCount(source) > 0
    else {
      log.warning("Invalid image source: \(path)")
      return nil
    }

    guard let thumbnailMaxPixelSize = thumbnailMaxPixelSize(for: source) else {
      log.warning("Invalid image dimensions: \(path)")
      return nil
    }

    let thumbnailOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
    ]

    guard
      let thumbnail = CGImageSourceCreateThumbnailAtIndex(
        source, 0, thumbnailOptions as CFDictionary
      )
    else {
      return nil
    }

    return opaqueRGBImage(from: thumbnail, maxPixelSize: nil)
  }

  private func downsample(cgImage: CGImage) -> CGImage? {
    opaqueRGBImage(from: cgImage, maxPixelSize: maxPixelSize)
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

    guard
      let metaString = try? String(contentsOf: metaURL, encoding: .utf8).trimmingCharacters(
        in: .whitespacesAndNewlines
      )
    else {
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

    guard
      let source = CGImageSourceCreateWithURL(
        jpegURL as CFURL, sourceOptions as CFDictionary
      )
    else {
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
      log.warning("Failed to create cache directory: \(error)")
      return
    }

    let jpegURL = diskCachePath(key: key, extension: "jpg")
    let metaURL = diskCachePath(key: key, extension: "meta")

    let cacheImage = opaqueRGBImage(from: image, maxPixelSize: nil) ?? image
    let rep = NSBitmapImageRep(cgImage: cacheImage)
    guard
      let jpegData = rep.representation(
        using: .jpeg, properties: [.compressionFactor: 0.85]
      )
    else {
      return
    }

    let tmpJPEG = cacheDirectory.appendingPathComponent(".\(key).jpg.tmp")
    let tmpMeta = cacheDirectory.appendingPathComponent(".\(key).meta.tmp")

    do {
      try jpegData.write(to: tmpJPEG, options: .atomic)
      _ = try FileManager.default.replaceItemAt(jpegURL, withItemAt: tmpJPEG)
    } catch {
      log.warning("Failed to write thumbnail: \(error)")
      try? FileManager.default.removeItem(at: tmpJPEG)
      return
    }

    let metaContent = sourceMtime.map { String($0) } ?? "bundled"
    do {
      try metaContent.write(to: tmpMeta, atomically: true, encoding: .utf8)
      _ = try FileManager.default.replaceItemAt(metaURL, withItemAt: tmpMeta)
    } catch {
      log.warning("Failed to write meta: \(error)")
      try? FileManager.default.removeItem(at: tmpMeta)
    }
  }

  // MARK: - Helpers
  private enum MemoryCacheKind {
    case thumbnail
    case fullImage
  }

  private func cachedMemoryImage(for key: String, kind: MemoryCacheKind) -> CGImage? {
    switch kind {
    case .thumbnail:
      guard let cached = thumbnailMemoryCache[key] else {
        return nil
      }
      recordMemoryAccess(for: key, kind: .thumbnail)
      return cached
    case .fullImage:
      guard let cached = fullImageMemoryCache[key] else {
        return nil
      }
      recordMemoryAccess(for: key, kind: .fullImage)
      return cached
    }
  }

  private func cacheMemoryImage(_ image: CGImage, for key: String, kind: MemoryCacheKind) {
    let limit: Int
    switch kind {
    case .thumbnail:
      limit = thumbnailMemoryLimit
    case .fullImage:
      limit = fullImageMemoryLimit
    }

    guard limit > 0 else {
      return
    }

    switch kind {
    case .thumbnail:
      thumbnailMemoryCache[key] = image
    case .fullImage:
      fullImageMemoryCache[key] = image
    }
    recordMemoryAccess(for: key, kind: kind)
    evictMemoryCacheIfNeeded(kind: kind, limit: limit)
  }

  private func recordMemoryAccess(for key: String, kind: MemoryCacheKind) {
    switch kind {
    case .thumbnail:
      thumbnailAccessOrder.removeAll { $0 == key }
      thumbnailAccessOrder.append(key)
    case .fullImage:
      fullImageAccessOrder.removeAll { $0 == key }
      fullImageAccessOrder.append(key)
    }
  }

  private func evictMemoryCacheIfNeeded(kind: MemoryCacheKind, limit: Int) {
    switch kind {
    case .thumbnail:
      while thumbnailMemoryCache.count > limit, let evictedKey = thumbnailAccessOrder.first {
        thumbnailAccessOrder.removeFirst()
        thumbnailMemoryCache.removeValue(forKey: evictedKey)
      }
    case .fullImage:
      while fullImageMemoryCache.count > limit, let evictedKey = fullImageAccessOrder.first {
        fullImageAccessOrder.removeFirst()
        fullImageMemoryCache.removeValue(forKey: evictedKey)
      }
    }
  }
}
