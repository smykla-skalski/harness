import AppKit
import Foundation
import ImageIO

/// In-memory avatar cache for the dependency-update PR timeline.
///
/// Built on `NSCache<NSURL, NSImage>` with a 64-entry cap plus an
/// in-flight dedupe table so multiple visible rows requesting the
/// same avatar do not fan out into N concurrent fetches. Downsamples
/// images via `CGImageSourceCreateThumbnailAtIndex` to the
/// view-requested pixel size so the cache stores compact pre-decoded
/// thumbnails rather than full-resolution PNGs — per the perf
/// discipline in plan §4.6 and the
/// `swiftui-performance-macos/references/image-optimization.md`
/// reference: `kCGImageSourceShouldCache: false` on the source +
/// `kCGImageSourceShouldCacheImmediately: true` on the thumbnail.
public actor ReviewAvatarCache {
  public static let shared = ReviewAvatarCache()

  private let cache: NSCache<NSURL, NSImage>
  private var inFlight: [URL: Task<NSImage?, Never>] = [:]
  private let urlSession: URLSession

  public init(countLimit: Int = 64, urlSession: URLSession = .shared) {
    let nsCache = NSCache<NSURL, NSImage>()
    nsCache.countLimit = countLimit
    self.cache = nsCache
    self.urlSession = urlSession
  }

  /// Returns a downsampled avatar for `url` sized for the given
  /// `targetPixel` (point × backing scale). Coalesces concurrent
  /// requests for the same URL into a single network fetch.
  public func avatar(for url: URL, targetPixel: CGFloat) async -> NSImage? {
    if let cached = cache.object(forKey: url as NSURL) {
      return cached
    }
    if let inflight = inFlight[url] {
      return await inflight.value
    }
    let task = Task { [self, url, targetPixel] in
      await Self.fetchAndDownsample(url: url, targetPixel: targetPixel, session: urlSession)
    }
    inFlight[url] = task
    defer { inFlight[url] = nil }
    let image = await task.value
    if let image {
      cache.setObject(image, forKey: url as NSURL)
    }
    return image
  }

  /// Test helper: drop every cached entry. Production code never
  /// needs to do this — the `countLimit` evicts on pressure.
  public func clear() {
    cache.removeAllObjects()
  }

  private static func fetchAndDownsample(
    url: URL,
    targetPixel: CGFloat,
    session: URLSession
  ) async -> NSImage? {
    do {
      let (data, response) = try await session.data(from: url)
      if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
        return nil
      }
      return downsample(data: data, targetPixel: targetPixel)
    } catch {
      return nil
    }
  }

  static func downsample(data: Data, targetPixel: CGFloat) -> NSImage? {
    let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
    guard
      let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary)
    else {
      return nil
    }
    let thumbnailOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: max(targetPixel, 32),
    ]
    guard
      let cgImage = CGImageSourceCreateThumbnailAtIndex(
        source,
        0,
        thumbnailOptions as CFDictionary
      )
    else {
      return nil
    }
    let size = NSSize(width: cgImage.width, height: cgImage.height)
    return NSImage(cgImage: cgImage, size: size)
  }
}
