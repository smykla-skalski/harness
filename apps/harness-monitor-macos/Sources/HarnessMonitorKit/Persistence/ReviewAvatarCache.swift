import AppKit
import Foundation
import ImageIO
import SwiftData

/// Avatar cache for the review PR timeline.
///
/// SwiftData persists daemon-fetched raw image bytes keyed by the exact
/// GitHub `avatarUrl`, while `NSCache` keeps bounded decoded thumbnails
/// per requested pixel size for scroll performance.
public actor ReviewAvatarCache {
  public static let shared = ReviewAvatarCache()

  private let cache: NSCache<NSString, NSImage>
  private var inFlight: [String: Task<NSImage?, Never>] = [:]

  public init(countLimit: Int = 64) {
    let nsCache = NSCache<NSString, NSImage>()
    nsCache.countLimit = countLimit
    self.cache = nsCache
  }

  /// Returns a downsampled avatar for `avatarURL` sized for the given
  /// `targetPixel` (point × backing scale). Coalesces concurrent requests
  /// and only asks the daemon when SwiftData does not already hold bytes
  /// for this exact avatar URL.
  public func avatar(
    for avatarURL: URL,
    targetPixel: CGFloat,
    modelContainer: ModelContainer,
    client: any HarnessMonitorReviewsClientProtocol
  ) async -> NSImage? {
    let key = Self.cacheKey(avatarURL: avatarURL, targetPixel: targetPixel)
    if let cached = cache.object(forKey: key as NSString) {
      return cached
    }
    if let inflight = inFlight[key] {
      return await inflight.value
    }
    let task = Task { [avatarURL, targetPixel, modelContainer, client] in
      await Self.loadOrFetchAndDownsample(
        avatarURL: avatarURL,
        targetPixel: targetPixel,
        modelContainer: modelContainer,
        client: client
      )
    }
    inFlight[key] = task
    defer { inFlight[key] = nil }
    let image = await task.value
    if let image {
      cache.setObject(image, forKey: key as NSString)
    }
    return image
  }

  /// Test helper: drop every cached entry. Production code never
  /// needs to do this — the `countLimit` evicts on pressure.
  public func clear() {
    cache.removeAllObjects()
  }

  public nonisolated static func fallbackAvatarURL(login: String) -> URL? {
    let trimmed = login.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    var components = URLComponents()
    components.scheme = "https"
    components.host = "github.com"
    components.path = "/\(trimmed).png"
    components.queryItems = [URLQueryItem(name: "size", value: "64")]
    return components.url
  }

  private static func loadOrFetchAndDownsample(
    avatarURL: URL,
    targetPixel: CGFloat,
    modelContainer: ModelContainer,
    client: any HarnessMonitorReviewsClientProtocol
  ) async -> NSImage? {
    if let data = cachedData(avatarURL: avatarURL, modelContainer: modelContainer) {
      return downsample(data: data, targetPixel: targetPixel)
    }
    do {
      let response = try await client.fetchReviewAvatar(
        request: ReviewsAvatarRequest(avatarURL: avatarURL.absoluteString)
      )
      guard let data = response.contentData else { return nil }
      store(
        response: response,
        data: data,
        modelContainer: modelContainer
      )
      return downsample(data: data, targetPixel: targetPixel)
    } catch {
      return nil
    }
  }

  private static func cachedData(
    avatarURL: URL,
    modelContainer: ModelContainer
  ) -> Data? {
    let key = avatarURL.absoluteString
    let context = ModelContext(modelContainer)
    let descriptor = FetchDescriptor<CachedReviewAvatar>(
      predicate: #Predicate { $0.avatarURL == key }
    )
    guard let row = try? context.fetch(descriptor).first else { return nil }
    row.lastAccessedAt = .now
    try? context.save()
    return row.contentData
  }

  private static func store(
    response: ReviewsAvatarResponse,
    data: Data,
    modelContainer: ModelContainer
  ) {
    let key = response.avatarURL
    let fetchedAt = parseFetchedAt(response.fetchedAt) ?? .now
    let context = ModelContext(modelContainer)
    let descriptor = FetchDescriptor<CachedReviewAvatar>(
      predicate: #Predicate { $0.avatarURL == key }
    )
    do {
      if let row = try context.fetch(descriptor).first {
        row.mimeType = response.mimeType
        row.contentData = data
        row.fetchedAt = fetchedAt
        row.lastAccessedAt = .now
      } else {
        context.insert(
          CachedReviewAvatar(
            avatarURL: key,
            mimeType: response.mimeType,
            contentData: data,
            fetchedAt: fetchedAt,
            lastAccessedAt: .now
          )
        )
      }
      try context.save()
    } catch {
      HarnessMonitorLogger.store.warning(
        "review.avatar_cache_write_failed error=\(String(describing: error), privacy: .public)"
      )
    }
  }

  private static func parseFetchedAt(_ string: String) -> Date? {
    if let date = try? Date(string, strategy: .iso8601) { return date }
    return try? Date(
      string,
      strategy: .iso8601.year().month().day()
        .dateSeparator(.dash)
        .time(includingFractionalSeconds: true)
        .timeZone(separator: .colon)
    )
  }

  private static func cacheKey(avatarURL: URL, targetPixel: CGFloat) -> String {
    "\(avatarURL.absoluteString)#\(Int(max(targetPixel, 32)))"
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
