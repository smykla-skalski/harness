import CryptoKit
import Foundation

/// Debounced on-disk patch cache for the Reviews > Files feature.
///
/// One JSON file per `(pullRequestID, headRefOid, path)` triple. The actor
/// coalesces writes that arrive within a 300ms window so a burst of patches
/// (e.g. when expanding a PR's first 25 files at once) becomes one disk
/// flush. LRU eviction keeps the on-disk footprint under
/// `diskCapBytes` (default 100 MB).
///
/// Reads are async because callers already `await` on patch fetch; the
/// actor isolation lets them see in-memory pending writes before the disk
/// flush lands.
public actor ReviewFilePatchStore {
  public struct Entry: Codable, Equatable, Sendable {
    public let patch: String
    public let etag: String?
    public let additions: UInt32
    public let deletions: UInt32
    public let truncated: Bool
    public let status: ReviewFileChangeType
    public let servedBy: ReviewFileServedBy
    public let fetchedAt: String

    public init(
      patch: String,
      etag: String? = nil,
      additions: UInt32 = 0,
      deletions: UInt32 = 0,
      truncated: Bool = false,
      status: ReviewFileChangeType = .modified,
      servedBy: ReviewFileServedBy = .githubRest,
      fetchedAt: String = ""
    ) {
      self.patch = patch
      self.etag = etag
      self.additions = additions
      self.deletions = deletions
      self.truncated = truncated
      self.status = status
      self.servedBy = servedBy
      self.fetchedAt = fetchedAt
    }
  }

  public static let defaultDiskCapBytes: Int = 100 * 1024 * 1024
  public static let defaultDebounceNanoseconds: UInt64 = 300_000_000

  private let directory: URL
  private let diskCapBytes: Int
  private let debounceNanoseconds: UInt64
  private let fileManager: FileManager
  private static let decoder = JSONDecoder()
  private static let encoder = JSONEncoder()
  private var pending: [String: Entry] = [:]
  private var pendingDeletes: Set<String> = []
  private var flushTask: Task<Void, Never>?

  public init(
    directory: URL,
    diskCapBytes: Int = ReviewFilePatchStore.defaultDiskCapBytes,
    debounceNanoseconds: UInt64 = ReviewFilePatchStore.defaultDebounceNanoseconds,
    fileManager: FileManager = .default
  ) {
    self.directory = directory
    self.diskCapBytes = diskCapBytes
    self.debounceNanoseconds = debounceNanoseconds
    self.fileManager = fileManager
  }

  // MARK: - Public API

  /// Look up the cached patch. Returns nil when nothing is on disk and
  /// nothing is queued for write under the same key.
  public func read(
    pullRequestID: String,
    headRefOid: String,
    path: String
  ) -> Entry? {
    let key = Self.makeKey(pullRequestID: pullRequestID, headRefOid: headRefOid, path: path)
    if pendingDeletes.contains(key) { return nil }
    if let queued = pending[key] { return queued }
    return readFromDisk(key: key)
  }

  /// Queue a patch for persistence. The actor coalesces writes in a 300ms
  /// debounce window and runs the flush via a detached Task so the call
  /// returns immediately.
  public func store(
    pullRequestID: String,
    headRefOid: String,
    path: String,
    entry: Entry
  ) {
    let key = Self.makeKey(pullRequestID: pullRequestID, headRefOid: headRefOid, path: path)
    pending[key] = entry
    pendingDeletes.remove(key)
    scheduleFlush()
  }

  /// Queue a deletion for the given key.
  public func remove(
    pullRequestID: String,
    headRefOid: String,
    path: String
  ) {
    let key = Self.makeKey(pullRequestID: pullRequestID, headRefOid: headRefOid, path: path)
    pending.removeValue(forKey: key)
    pendingDeletes.insert(key)
    scheduleFlush()
  }

  /// Discard every cached patch (memory + disk). Used by the diagnostic
  /// "Clear Session Cache" action.
  public func clear() {
    pending.removeAll()
    pendingDeletes.removeAll()
    flushTask?.cancel()
    flushTask = nil
    guard fileManager.fileExists(atPath: directory.path) else { return }
    if let contents = try? fileManager.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
    {
      for url in contents {
        try? fileManager.removeItem(at: url)
      }
    }
  }

  /// Wait until any pending debounced flush has completed. Used by tests
  /// and shutdown paths to guarantee the disk is up to date.
  public func flushPending() async {
    if let task = flushTask {
      await task.value
    }
    if !pending.isEmpty || !pendingDeletes.isEmpty {
      await runFlush()
    }
  }

  /// Total bytes used on disk by patch entries. Used by tests + Settings
  /// diagnostics.
  public func currentDiskBytes() -> Int {
    diskEntries().reduce(0) { $0 + $1.size }
  }

  // MARK: - Internals

  private func scheduleFlush() {
    flushTask?.cancel()
    let debounce = debounceNanoseconds
    flushTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: debounce)
      guard !Task.isCancelled else { return }
      await self?.runFlush()
    }
  }

  private func runFlush() async {
    flushTask = nil
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      for key in pendingDeletes {
        let url = fileURL(forKey: key)
        try? fileManager.removeItem(at: url)
      }
      for (key, entry) in pending {
        let url = fileURL(forKey: key)
        do {
          let data = try Self.encoder.encode(entry)
          try data.write(to: url, options: .atomic)
        } catch {
          HarnessMonitorLogger.store.warning(
            """
            ReviewFilePatchStore flush failed; \
            key=\(key, privacy: .public) \
            error=\(String(reflecting: error), privacy: .public)
            """
          )
        }
      }
      pending.removeAll()
      pendingDeletes.removeAll()
      enforceLRU()
    } catch {
      HarnessMonitorLogger.store.warning(
        """
        ReviewFilePatchStore directory create failed; \
        path=\(self.directory.path, privacy: .public) \
        error=\(String(reflecting: error), privacy: .public)
        """
      )
    }
  }

  private func enforceLRU() {
    let entries = diskEntries()
    var totalBytes = entries.reduce(0) { $0 + $1.size }
    guard totalBytes > diskCapBytes else { return }
    let oldestFirst = entries.sorted { $0.mtime < $1.mtime }
    for entry in oldestFirst where totalBytes > diskCapBytes {
      do {
        try fileManager.removeItem(at: entry.url)
        totalBytes -= entry.size
      } catch {
        HarnessMonitorLogger.store.warning(
          """
          ReviewFilePatchStore LRU evict failed; \
          path=\(entry.url.path, privacy: .public) \
          error=\(String(reflecting: error), privacy: .public)
          """
        )
      }
    }
  }

  private func readFromDisk(key: String) -> Entry? {
    let url = fileURL(forKey: key)
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    do {
      let data = try Data(contentsOf: url)
      let entry = try Self.decoder.decode(Entry.self, from: data)
      try? fileManager.setAttributes([.modificationDate: Date.now], ofItemAtPath: url.path)
      return entry
    } catch {
      return nil
    }
  }

  private struct DiskEntry {
    let url: URL
    let size: Int
    let mtime: Date
  }

  private func diskEntries() -> [DiskEntry] {
    guard fileManager.fileExists(atPath: directory.path) else { return [] }
    let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
    guard
      let urls = try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: keys
      )
    else {
      return []
    }
    return urls.compactMap { url in
      guard let resourceValues = try? url.resourceValues(forKeys: Set(keys)),
        let size = resourceValues.fileSize,
        let mtime = resourceValues.contentModificationDate
      else {
        return nil
      }
      return DiskEntry(url: url, size: size, mtime: mtime)
    }
  }

  private func fileURL(forKey key: String) -> URL {
    directory.appendingPathComponent("\(key).json", isDirectory: false)
  }

  static func makeKey(pullRequestID: String, headRefOid: String, path: String) -> String {
    let raw = "\(pullRequestID)\u{1F}\(headRefOid)\u{1F}\(path)"
    let digest = SHA256.hash(data: Data(raw.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}
