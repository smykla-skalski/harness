import Foundation
import OSLog

/// Persistent on-disk URLCache backing the entity-picker images.
/// `DisplayRepresentation.Image(url:)` on PullRequestEntity and
/// RepositoryEntity points at `https://github.com/<login>.png`; the
/// system's renderer uses URLSession which consults `URLCache.shared`.
/// Default URLCache is in-memory and dies with the extension process,
/// so every Spotlight pick refetched the same avatar over the network
///
/// This module configures `URLCache.shared` to a disk-backed cache in
/// the shared App Group container so avatars survive extension launches.
/// Capacity is 4 MB memory plus 16 MB disk - enough for hundreds of
/// distinct GitHub avatars at ~50-60 KB each. Bootstrap runs exactly
/// once per process via `IntentDaemonClientCache.shared` init, which
/// every daemon source touches on first call
public enum IntentImageCache {
  static let appGroupSuiteName = "Q498EB36N4.io.harnessmonitor"
  static let cacheSubdirectory = "Caches/EntityImages"
  static let memoryCapacity = 4 * 1024 * 1024
  static let diskCapacity = 16 * 1024 * 1024

  private static let logger = Logger(
    subsystem: "io.harnessmonitor.intents", category: "image-cache"
  )

  private static let bootstrapToken: Bool = {
    configureSharedCache()
    return true
  }()

  /// Idempotent boot. Subsequent calls are no-ops because the static
  /// `bootstrapToken` is computed lazily on first reference
  public static func bootstrap() {
    _ = bootstrapToken
  }

  /// Reset the underlying static state for tests. Production callers
  /// must never invoke this - it deliberately rebuilds the cache
  static func resetForTesting() {
    URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0, directory: nil)
  }

  /// Replaces `URLCache.shared` with a disk-backed cache rooted in the
  /// App Group container. Falls back to the default in-memory cache if
  /// the App Group container is unavailable
  static func configureSharedCache() {
    let directory = appGroupCacheDirectory()
    let cache = URLCache(
      memoryCapacity: memoryCapacity,
      diskCapacity: diskCapacity,
      directory: directory
    )
    URLCache.shared = cache
    if directory == nil {
      logger.warning(
        "App Group container unavailable for image cache; falling back to in-memory URLCache"
      )
    }
  }

  /// App Group container path used as the URLCache disk root. Returns
  /// nil if the App Group is not available (test process, simulator
  /// without the entitlement, etc.) so callers can surface a degraded
  /// in-memory cache
  static func appGroupCacheDirectory() -> URL? {
    let fm = FileManager.default
    guard
      let container = fm.containerURL(
        forSecurityApplicationGroupIdentifier: appGroupSuiteName
      )
    else {
      return nil
    }
    let url = container.appendingPathComponent(cacheSubdirectory, isDirectory: true)
    try? fm.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Fire-and-forget warm of the URLCache for the given URL. Called
  /// from donation helpers so a freshly-donated PR or repo has its
  /// avatar ready before the next Spotlight pick - the URLSession
  /// request lands the bytes in URLCache.shared, which is what the
  /// system renderer reads from
  public static func prewarm(_ url: URL) {
    bootstrap()
    Task.detached(priority: .utility) {
      var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
      request.timeoutInterval = 5
      _ = try? await URLSession.shared.data(for: request)
    }
  }
}
