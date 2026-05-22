import CoreGraphics
import Foundation
import ImageIO

/// Off-main image decoder for the Dependencies > Files image preview.
///
/// Wraps `CGImageSourceCreateThumbnailAtIndex` so decode happens on the
/// actor's executor instead of on the main thread. The in-memory LRU is
/// capped by approximate decoded byte count (default 64 MB) rather than
/// entry count - one 4K asset is roughly 32 MB on its own, so an
/// entry-count cap underestimates real cost.
public actor DependencyUpdateImageDecoder {
  public struct PreparedImage: @unchecked Sendable, Equatable {
    public let cgImage: CGImage
    public let intrinsicSize: CGSize
    public let byteSize: Int

    public init(cgImage: CGImage, intrinsicSize: CGSize, byteSize: Int) {
      self.cgImage = cgImage
      self.intrinsicSize = intrinsicSize
      self.byteSize = byteSize
    }

    public static func == (lhs: PreparedImage, rhs: PreparedImage) -> Bool {
      lhs.cgImage === rhs.cgImage
        && lhs.intrinsicSize == rhs.intrinsicSize
        && lhs.byteSize == rhs.byteSize
    }
  }

  public struct CacheKey: Hashable, Sendable {
    public let repositoryID: String
    public let oid: String
    public let displaySizeBucket: Int

    public init(repositoryID: String, oid: String, displaySizeBucket: Int) {
      self.repositoryID = repositoryID
      self.oid = oid
      self.displaySizeBucket = displaySizeBucket
    }
  }

  public enum DecodeError: Error, Equatable, Sendable {
    case imageSourceCreationFailed
    case thumbnailCreationFailed
  }

  public static let defaultMaxBytes: Int = 64 * 1024 * 1024

  private let maxBytes: Int
  private var cache: [CacheKey: PreparedImage] = [:]
  private var insertionOrder: [CacheKey] = []
  private var currentByteTotal: Int = 0

  public init(maxBytes: Int = DependencyUpdateImageDecoder.defaultMaxBytes) {
    self.maxBytes = maxBytes
  }

  // MARK: - Public API

  public func cached(
    repositoryID: String,
    oid: String,
    displayMaxDimension: Int
  ) -> PreparedImage? {
    let key = makeKey(
      repositoryID: repositoryID,
      oid: oid,
      displayMaxDimension: displayMaxDimension
    )
    guard let entry = cache[key] else { return nil }
    promoteRecentlyUsed(key: key)
    return entry
  }

  /// Decode the supplied raw image bytes (PNG / JPEG / GIF / static SVG
  /// already rasterized). Throws `DecodeError` when ImageIO refuses.
  public func decode(
    repositoryID: String,
    oid: String,
    displayMaxDimension: Int,
    data: Data
  ) throws -> PreparedImage {
    let key = makeKey(
      repositoryID: repositoryID,
      oid: oid,
      displayMaxDimension: displayMaxDimension
    )
    if let cached = cache[key] {
      promoteRecentlyUsed(key: key)
      return cached
    }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
      throw DecodeError.imageSourceCreationFailed
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: max(displayMaxDimension, 1),
    ]
    guard
      let cgImage = CGImageSourceCreateThumbnailAtIndex(
        source, 0, options as CFDictionary
      )
    else {
      throw DecodeError.thumbnailCreationFailed
    }
    let intrinsicSize = Self.intrinsicSize(from: source) ?? CGSize(
      width: CGFloat(cgImage.width),
      height: CGFloat(cgImage.height)
    )
    let byteSize = cgImage.width * cgImage.height * 4
    let prepared = PreparedImage(
      cgImage: cgImage,
      intrinsicSize: intrinsicSize,
      byteSize: byteSize
    )
    insert(key: key, prepared: prepared)
    return prepared
  }

  /// Drop every cached PreparedImage. Used by the diagnostic "Clear
  /// Session Cache" action and on Settings changes that invalidate
  /// outputs (e.g. image cap toggle).
  public func clear() {
    cache.removeAll()
    insertionOrder.removeAll()
    currentByteTotal = 0
  }

  /// Total decoded bytes currently held in memory. Used by tests + the
  /// Settings diagnostics surface.
  public func currentBytes() -> Int { currentByteTotal }

  /// Bucket map for a max-dimension display size. Exposed so the store
  /// extensions can construct stable cache keys without re-importing the
  /// bucketing rule.
  public static func bucket(forDisplayMaxDimension dimension: Int) -> Int {
    guard dimension > 0 else { return 1 }
    var bucket = 1
    while bucket < dimension { bucket <<= 1 }
    return bucket
  }

  // MARK: - Internals

  private func makeKey(
    repositoryID: String,
    oid: String,
    displayMaxDimension: Int
  ) -> CacheKey {
    CacheKey(
      repositoryID: repositoryID,
      oid: oid,
      displaySizeBucket: Self.bucket(forDisplayMaxDimension: displayMaxDimension)
    )
  }

  private func insert(key: CacheKey, prepared: PreparedImage) {
    if cache[key] == nil {
      insertionOrder.append(key)
    } else {
      // Replace existing entry - subtract its byte size first so the LRU
      // total stays accurate.
      if let existing = cache[key] {
        currentByteTotal -= existing.byteSize
      }
      promoteRecentlyUsed(key: key)
    }
    cache[key] = prepared
    currentByteTotal += prepared.byteSize
    evictUntilUnderCap()
  }

  private func promoteRecentlyUsed(key: CacheKey) {
    insertionOrder.removeAll { $0 == key }
    insertionOrder.append(key)
  }

  private func evictUntilUnderCap() {
    while currentByteTotal > maxBytes, let oldest = insertionOrder.first {
      insertionOrder.removeFirst()
      if let evicted = cache.removeValue(forKey: oldest) {
        currentByteTotal -= evicted.byteSize
      }
    }
  }

  private static func intrinsicSize(from source: CGImageSource) -> CGSize? {
    guard
      let properties = CGImageSourceCopyPropertiesAtIndex(
        source, 0, nil
      ) as? [CFString: Any]
    else {
      return nil
    }
    let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue
    let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue
    guard let width, let height else { return nil }
    return CGSize(width: width, height: height)
  }
}
