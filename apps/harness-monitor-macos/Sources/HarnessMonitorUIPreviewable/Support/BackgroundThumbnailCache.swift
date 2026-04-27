import AppKit
import HarnessMonitorKit
import ImageIO
import os

private let log = Logger(subsystem: "io.harnessmonitor", category: "thumbnail")

public actor BackgroundThumbnailCache {
  public static let shared = BackgroundThumbnailCache()

  let cacheDirectory: URL
  let maxPixelSize: Int
  let maxFullImagePixelSize: Int
  let thumbnailMemoryLimit: Int
  let fullImageMemoryLimit: Int
  let thumbnailMemoryByteLimit: Int
  let fullImageMemoryByteLimit: Int
  var thumbnailMemoryCache: [String: CGImage] = [:]
  var fullImageMemoryCache: [String: CGImage] = [:]
  var thumbnailMemoryCacheByteCost = 0
  var fullImageMemoryCacheByteCost = 0
  private var thumbnailAccessOrder: [String] = []
  private var fullImageAccessOrder: [String] = []
  private var thumbnailTasks: [String: Task<CGImage?, Never>] = [:]
  private var fullImageTasks: [String: Task<CGImage?, Never>] = [:]

  static let allowedPathPrefixes = ["/System/Library/", "/Library/"]
  static let allowedExtensions: Set<String> = ["heic", "jpg", "jpeg", "png", "tiff"]
  static let maxFileSize: Int64 = 200 * 1024 * 1024

  public init(
    cacheDirectory: URL = HarnessMonitorPaths.thumbnailCacheRoot(),
    maxPixelSize: Int = 512,
    maxFullImagePixelSize: Int = 2_560,
    thumbnailMemoryLimit: Int = 24,
    fullImageMemoryLimit: Int = 1,
    thumbnailMemoryByteLimit: Int = 48 * 1024 * 1024,
    fullImageMemoryByteLimit: Int = 32 * 1024 * 1024
  ) {
    self.cacheDirectory = cacheDirectory
    self.maxPixelSize = maxPixelSize
    self.maxFullImagePixelSize = maxFullImagePixelSize
    self.thumbnailMemoryLimit = max(0, thumbnailMemoryLimit)
    self.fullImageMemoryLimit = max(0, fullImageMemoryLimit)
    self.thumbnailMemoryByteLimit = max(0, thumbnailMemoryByteLimit)
    self.fullImageMemoryByteLimit = max(0, fullImageMemoryByteLimit)
  }

  // MARK: - Public

  public func thumbnail(for selection: HarnessMonitorBackgroundSelection) async -> CGImage? {
    let key = cacheKey(for: selection)

    if let cached = cachedMemoryImage(for: key, kind: .thumbnail) {
      return cached
    }

    if let task = thumbnailTasks[key] {
      return await task.value
    }

    let priority = Self.imageGenerationPriority(for: Task.currentPriority)
    let task = Task.detached(priority: priority) { [self] in
      generateThumbnail(key: key, selection: selection)
    }
    thumbnailTasks[key] = task
    let generated = await task.value
    thumbnailTasks[key] = nil

    if let generated {
      cacheMemoryImage(generated, for: key, kind: .thumbnail)
    }
    return generated
  }

  public func fullImage(for selection: HarnessMonitorBackgroundSelection) async -> CGImage? {
    let key = "full:\(cacheKey(for: selection))"

    if let cached = cachedMemoryImage(for: key, kind: .fullImage) {
      return cached
    }

    if let task = fullImageTasks[key] {
      return await task.value
    }

    let priority = Self.imageGenerationPriority(for: Task.currentPriority)
    let task = Task.detached(priority: priority) { [self] in
      generateFullImage(selection: selection)
    }
    fullImageTasks[key] = task
    let generated = await task.value
    fullImageTasks[key] = nil

    if let generated {
      cacheMemoryImage(generated, for: key, kind: .fullImage)
    }
    return generated
  }

  public func prefetch(_ selections: [HarnessMonitorBackgroundSelection]) async {
    for selection in selections {
      if Task.isCancelled { return }
      _ = await thumbnail(for: selection)
    }
  }

  static func imageGenerationPriority(for _: TaskPriority) -> TaskPriority {
    .medium
  }

  // MARK: - Off-actor generation

  nonisolated private func generateThumbnail(
    key: String,
    selection: HarnessMonitorBackgroundSelection
  ) -> CGImage? {
    switch selection.source {
    case .bundled(let image):
      return generateBundledThumbnail(key: key, image: image)
    case .system(let wallpaper):
      return generateSystemThumbnail(key: key, wallpaper: wallpaper)
    }
  }

  nonisolated private func generateFullImage(
    selection: HarnessMonitorBackgroundSelection
  ) -> CGImage? {
    switch selection.source {
    case .bundled(let image):
      return generateBundledFullImage(image: image)
    case .system(let wallpaper):
      return generateSystemFullImage(wallpaper: wallpaper)
    }
  }

  nonisolated private func generateBundledThumbnail(
    key: String,
    image: HarnessMonitorBackgroundImage
  ) -> CGImage? {
    if let diskImage = loadFromDiskCache(key: key, expectedMtime: nil) {
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
    return thumbnail
  }

  nonisolated private func generateBundledFullImage(
    image: HarnessMonitorBackgroundImage
  ) -> CGImage? {
    guard let nsImage = HarnessMonitorUIAssets.bundle.image(forResource: image.assetName) else {
      return nil
    }
    guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      return nil
    }
    return opaqueRGBImage(from: cgImage, maxPixelSize: maxFullImagePixelSize)
  }

  nonisolated private func generateSystemThumbnail(
    key: String,
    wallpaper: HarnessMonitorSystemWallpaper
  ) -> CGImage? {
    guard validateSourcePath(wallpaper.imagePath) else {
      return nil
    }

    let sourceMtime = fileMtime(at: wallpaper.imagePath)

    if let diskImage = loadFromDiskCache(key: key, expectedMtime: sourceMtime) {
      return diskImage
    }

    guard let thumbnail = downsampleFile(at: wallpaper.imagePath, maximumPixelSize: maxPixelSize)
    else {
      log.warning("Failed to generate thumbnail: \(wallpaper.imagePath)")
      return nil
    }

    saveToDiskCache(image: thumbnail, key: key, sourceMtime: sourceMtime)
    return thumbnail
  }

  nonisolated private func generateSystemFullImage(
    wallpaper: HarnessMonitorSystemWallpaper
  ) -> CGImage? {
    guard validateSourcePath(wallpaper.imagePath) else {
      return nil
    }

    return downsampleFile(at: wallpaper.imagePath, maximumPixelSize: maxFullImagePixelSize)
  }

  // MARK: - Security validation

  nonisolated private func validateSourcePath(_ path: String) -> Bool {
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

  nonisolated private func downsampleFile(at path: String, maximumPixelSize: Int) -> CGImage? {
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

    guard
      let sourceMaxPixelSize = thumbnailMaxPixelSize(for: source),
      maximumPixelSize > 0
    else {
      log.warning("Invalid image dimensions: \(path)")
      return nil
    }
    let targetMaxPixelSize = min(sourceMaxPixelSize, maximumPixelSize)

    let thumbnailOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: targetMaxPixelSize,
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

  nonisolated private func downsample(cgImage: CGImage) -> CGImage? {
    opaqueRGBImage(from: cgImage, maxPixelSize: maxPixelSize)
  }

  // MARK: - Memory cache
  enum MemoryCacheKind {
    case thumbnail
    case fullImage
  }

  func cachedMemoryImage(for key: String, kind: MemoryCacheKind) -> CGImage? {
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

  func cacheMemoryImage(_ image: CGImage, for key: String, kind: MemoryCacheKind) {
    let countLimit: Int
    let byteLimit: Int
    switch kind {
    case .thumbnail:
      countLimit = thumbnailMemoryLimit
      byteLimit = thumbnailMemoryByteLimit
    case .fullImage:
      countLimit = fullImageMemoryLimit
      byteLimit = fullImageMemoryByteLimit
    }

    guard countLimit > 0, byteLimit > 0 else {
      removeMemoryImage(for: key, kind: kind)
      return
    }
    let imageCost = memoryCost(of: image)
    guard imageCost <= byteLimit else {
      removeMemoryImage(for: key, kind: kind)
      return
    }

    switch kind {
    case .thumbnail:
      if let existing = thumbnailMemoryCache[key] {
        thumbnailMemoryCacheByteCost -= memoryCost(of: existing)
      }
      thumbnailMemoryCache[key] = image
      thumbnailMemoryCacheByteCost += imageCost
    case .fullImage:
      if let existing = fullImageMemoryCache[key] {
        fullImageMemoryCacheByteCost -= memoryCost(of: existing)
      }
      fullImageMemoryCache[key] = image
      fullImageMemoryCacheByteCost += imageCost
    }
    recordMemoryAccess(for: key, kind: kind)
    evictMemoryCacheIfNeeded(kind: kind, countLimit: countLimit, byteLimit: byteLimit)
  }

  private func memoryCost(of image: CGImage) -> Int {
    image.bytesPerRow * image.height
  }

  private func removeMemoryImage(for key: String, kind: MemoryCacheKind) {
    switch kind {
    case .thumbnail:
      if let removed = thumbnailMemoryCache.removeValue(forKey: key) {
        thumbnailMemoryCacheByteCost -= memoryCost(of: removed)
      }
      thumbnailAccessOrder.removeAll { $0 == key }
    case .fullImage:
      if let removed = fullImageMemoryCache.removeValue(forKey: key) {
        fullImageMemoryCacheByteCost -= memoryCost(of: removed)
      }
      fullImageAccessOrder.removeAll { $0 == key }
    }
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

  private func evictMemoryCacheIfNeeded(
    kind: MemoryCacheKind,
    countLimit: Int,
    byteLimit: Int
  ) {
    switch kind {
    case .thumbnail:
      while thumbnailMemoryCache.count > countLimit || thumbnailMemoryCacheByteCost > byteLimit,
        let evictedKey = thumbnailAccessOrder.first
      {
        thumbnailAccessOrder.removeFirst()
        if let removed = thumbnailMemoryCache.removeValue(forKey: evictedKey) {
          thumbnailMemoryCacheByteCost -= memoryCost(of: removed)
        }
      }
    case .fullImage:
      while fullImageMemoryCache.count > countLimit || fullImageMemoryCacheByteCost > byteLimit,
        let evictedKey = fullImageAccessOrder.first
      {
        fullImageAccessOrder.removeFirst()
        if let removed = fullImageMemoryCache.removeValue(forKey: evictedKey) {
          fullImageMemoryCacheByteCost -= memoryCost(of: removed)
        }
      }
    }
  }
}
