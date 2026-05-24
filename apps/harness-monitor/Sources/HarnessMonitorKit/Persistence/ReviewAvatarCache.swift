import AppKit
import Foundation
import ImageIO
import SwiftData

/// Avatar cache for the review PR timeline.
///
/// SwiftData persists raw image bytes keyed by the exact GitHub `avatarUrl`,
/// while `NSCache` keeps bounded decoded thumbnails per requested pixel size
/// for scroll performance. Network misses are deduplicated by avatar URL, use
/// a small concurrency cap, and apply short-lived failure backoff so a broken
/// connection does not keep hammering the same avatar host.
public actor ReviewAvatarCache {
  public static let shared = ReviewAvatarCache()

  private struct RawAvatarPayload: Sendable {
    let data: Data
    let mimeType: String
    let fetchedAt: Date
  }

  private let cache: NSCache<NSString, NSImage>
  private let session: URLSession
  private let maxConcurrentFetches: Int
  private var imageInFlight: [String: Task<NSImage?, Never>] = [:]
  private var rawFetchInFlight: [String: Task<RawAvatarPayload?, Never>] = [:]
  private var recentFailures: [String: Date] = [:]
  private var recentFailureOrder: [String] = []
  private var activeFetchCount = 0
  private var fetchWaiters: [CheckedContinuation<Void, Never>] = []

  private static let requestTimeout: TimeInterval = 15
  private static let resourceTimeout: TimeInterval = 30
  private static let accessTouchInterval: TimeInterval = 60 * 60
  private static let failureBackoffInterval: TimeInterval = 60
  private static let failureCacheLimit = 256
  private static let maxAvatarBytes = 256 * 1024

  public init(
    countLimit: Int = 64,
    session: URLSession? = nil,
    maxConcurrentFetches: Int = 4
  ) {
    let nsCache = NSCache<NSString, NSImage>()
    nsCache.countLimit = countLimit
    self.cache = nsCache
    self.maxConcurrentFetches = max(1, maxConcurrentFetches)
    if let session {
      self.session = session
    } else {
      let configuration = URLSessionConfiguration.default
      configuration.timeoutIntervalForRequest = Self.requestTimeout
      configuration.timeoutIntervalForResource = Self.resourceTimeout
      configuration.httpMaximumConnectionsPerHost = max(1, maxConcurrentFetches)
      self.session = URLSession(configuration: configuration)
    }
  }

  /// Returns a downsampled avatar for `avatarURL` sized for the given
  /// `targetPixel` (point × backing scale). Coalesces concurrent requests
  /// and only reaches GitHub when SwiftData does not already hold bytes for
  /// this exact avatar URL.
  public func avatar(
    for avatarURL: URL,
    targetPixel: CGFloat,
    modelContainer: ModelContainer? = nil
  ) async -> NSImage? {
    let key = Self.cacheKey(avatarURL: avatarURL, targetPixel: targetPixel)
    if let cached = cache.object(forKey: key as NSString) {
      return cached
    }
    if let inflight = imageInFlight[key] {
      return await inflight.value
    }
    let task: Task<NSImage?, Never> = Task { [avatarURL, targetPixel, modelContainer] in
      guard
        let data = await self.cachedOrFetchedData(
          avatarURL: avatarURL,
          modelContainer: modelContainer
        )
      else {
        return nil
      }
      return Self.downsample(data: data, targetPixel: targetPixel)
    }
    imageInFlight[key] = task
    defer { imageInFlight[key] = nil }
    let image = await task.value
    if let image {
      cache.setObject(image, forKey: key as NSString)
    }
    return image
  }

  /// Test helper: drop every cached entry. Production code never
  /// needs to do this — the `countLimit` evicts on pressure.
  public func clear() {
    for task in imageInFlight.values {
      task.cancel()
    }
    for task in rawFetchInFlight.values {
      task.cancel()
    }
    for waiter in fetchWaiters {
      waiter.resume()
    }
    cache.removeAllObjects()
    imageInFlight.removeAll()
    rawFetchInFlight.removeAll()
    recentFailures.removeAll()
    recentFailureOrder.removeAll()
    fetchWaiters.removeAll()
    activeFetchCount = 0
  }

  nonisolated public static func fallbackAvatarURL(login: String) -> URL? {
    let trimmed = login.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    var components = URLComponents()
    components.scheme = "https"
    components.host = "github.com"
    components.path = "/\(trimmed).png"
    components.queryItems = [URLQueryItem(name: "size", value: "64")]
    return components.url
  }

  private func cachedOrFetchedData(
    avatarURL: URL,
    modelContainer: ModelContainer?
  ) async -> Data? {
    let key = avatarURL.absoluteString
    let now = Date()
    purgeExpiredFailures(now: now)

    if let data = Self.cachedData(
      avatarURL: avatarURL,
      modelContainer: modelContainer,
      now: now
    ) {
      clearFailure(for: key)
      return data
    }

    guard Self.isAllowedAvatarURL(avatarURL) else {
      return nil
    }

    if shouldBackOff(avatarURL: key, now: now) {
      return nil
    }

    if let inflight = rawFetchInFlight[key] {
      return await inflight.value?.data
    }

    let task = Task { [avatarURL] in
      await self.fetchRemoteAvatar(avatarURL: avatarURL)
    }
    rawFetchInFlight[key] = task
    defer { rawFetchInFlight[key] = nil }

    guard let payload = await task.value else {
      recordFailure(for: key, at: Date())
      return nil
    }

    clearFailure(for: key)
    if let modelContainer {
      Self.store(
        payload: payload,
        avatarURL: key,
        modelContainer: modelContainer
      )
    }
    return payload.data
  }

  private func fetchRemoteAvatar(avatarURL: URL) async -> RawAvatarPayload? {
    await acquireFetchSlot()
    defer { releaseFetchSlot() }

    var request = URLRequest(url: avatarURL)
    request.timeoutInterval = Self.requestTimeout

    do {
      let (data, response) = try await session.data(for: request)
      guard
        let http = response as? HTTPURLResponse,
        (200..<300).contains(http.statusCode),
        data.count <= Self.maxAvatarBytes
      else {
        return nil
      }
      let mimeType =
        Self.normalizeMimeType(http.value(forHTTPHeaderField: "Content-Type"))
        ?? "image/png"
      return RawAvatarPayload(
        data: data,
        mimeType: mimeType,
        fetchedAt: .now
      )
    } catch {
      return nil
    }
  }

  private func acquireFetchSlot() async {
    guard activeFetchCount >= maxConcurrentFetches else {
      activeFetchCount += 1
      return
    }
    await withCheckedContinuation { continuation in
      fetchWaiters.append(continuation)
    }
  }

  private func releaseFetchSlot() {
    if let waiter = fetchWaiters.first {
      fetchWaiters.removeFirst()
      waiter.resume()
      return
    }
    if activeFetchCount > 0 {
      activeFetchCount -= 1
    }
  }

  private func shouldBackOff(avatarURL: String, now: Date) -> Bool {
    guard let failedAt = recentFailures[avatarURL] else {
      return false
    }
    return now.timeIntervalSince(failedAt) < Self.failureBackoffInterval
  }

  private func recordFailure(for avatarURL: String, at now: Date) {
    if recentFailures[avatarURL] == nil {
      recentFailureOrder.append(avatarURL)
    }
    recentFailures[avatarURL] = now
    while recentFailureOrder.count > Self.failureCacheLimit {
      let removed = recentFailureOrder.removeFirst()
      recentFailures.removeValue(forKey: removed)
    }
  }

  private func clearFailure(for avatarURL: String) {
    recentFailures.removeValue(forKey: avatarURL)
    recentFailureOrder.removeAll { $0 == avatarURL }
  }

  private func purgeExpiredFailures(now: Date) {
    recentFailureOrder.removeAll { avatarURL in
      guard let failedAt = recentFailures[avatarURL] else {
        return true
      }
      if now.timeIntervalSince(failedAt) >= Self.failureBackoffInterval {
        recentFailures.removeValue(forKey: avatarURL)
        return true
      }
      return false
    }
  }

  private static func cachedData(
    avatarURL: URL,
    modelContainer: ModelContainer?,
    now: Date
  ) -> Data? {
    guard let modelContainer else {
      return nil
    }
    let key = avatarURL.absoluteString
    let context = ModelContext(modelContainer)
    let descriptor = FetchDescriptor<CachedReviewAvatar>(
      predicate: #Predicate { $0.avatarURL == key }
    )
    guard let row = try? context.fetch(descriptor).first else { return nil }
    if now.timeIntervalSince(row.lastAccessedAt) >= Self.accessTouchInterval {
      row.lastAccessedAt = now
      try? context.save()
    }
    return row.contentData
  }

  private static func store(
    payload: RawAvatarPayload,
    avatarURL: String,
    modelContainer: ModelContainer
  ) {
    let context = ModelContext(modelContainer)
    let descriptor = FetchDescriptor<CachedReviewAvatar>(
      predicate: #Predicate { $0.avatarURL == avatarURL }
    )
    do {
      if let row = try context.fetch(descriptor).first {
        row.mimeType = payload.mimeType
        row.contentData = payload.data
        row.fetchedAt = payload.fetchedAt
        row.lastAccessedAt = .now
      } else {
        context.insert(
          CachedReviewAvatar(
            avatarURL: avatarURL,
            mimeType: payload.mimeType,
            contentData: payload.data,
            fetchedAt: payload.fetchedAt,
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

  private static func cacheKey(avatarURL: URL, targetPixel: CGFloat) -> String {
    "\(avatarURL.absoluteString)#\(Int(max(targetPixel, 32)))"
  }

  private static func isAllowedAvatarURL(_ avatarURL: URL) -> Bool {
    guard avatarURL.scheme == "https" else {
      return false
    }
    guard let host = avatarURL.host?.lowercased() else {
      return false
    }
    return host == "avatars.githubusercontent.com" || host == "github.com"
  }

  private static func normalizeMimeType(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let mimeType = raw.split(separator: ";").first?.trimmingCharacters(in: .whitespaces)
      .lowercased()
    guard let mimeType, mimeType.hasPrefix("image/") else {
      return nil
    }
    return mimeType
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
