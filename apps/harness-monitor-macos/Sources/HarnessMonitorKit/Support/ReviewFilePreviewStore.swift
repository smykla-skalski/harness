import CryptoKit
import Foundation

/// Debounced on-disk preview cache for the Reviews > Files expansion path.
///
/// One JSON file per `(pullRequestID, headRefOid, path, lineLimit)` tuple.
/// The head OID keeps force-pushes isolated, while the line limit prevents a
/// smaller preview from satisfying a request for a larger first-lines window.
public actor ReviewFilePreviewStore {
  public static let defaultDiskCapBytes: Int = 25 * 1024 * 1024
  public static let defaultDebounceNanoseconds: UInt64 = 300_000_000

  private let directory: URL
  private let diskCapBytes: Int
  private let debounceNanoseconds: UInt64
  private let fileManager: FileManager
  private static let decoder = JSONDecoder()
  private static let encoder = JSONEncoder()
  private var pending: [String: ReviewFilePreview] = [:]
  private var pendingDeletes: Set<String> = []
  private var flushTask: Task<Void, Never>?

  public init(
    directory: URL,
    diskCapBytes: Int = ReviewFilePreviewStore.defaultDiskCapBytes,
    debounceNanoseconds: UInt64 = ReviewFilePreviewStore.defaultDebounceNanoseconds,
    fileManager: FileManager = .default
  ) {
    self.directory = directory
    self.diskCapBytes = diskCapBytes
    self.debounceNanoseconds = debounceNanoseconds
    self.fileManager = fileManager
  }

  public func read(
    pullRequestID: String,
    headRefOid: String,
    path: String,
    lineLimit: UInt32
  ) -> ReviewFilePreview? {
    let key = Self.makeKey(
      pullRequestID: pullRequestID,
      headRefOid: headRefOid,
      path: path,
      lineLimit: lineLimit
    )
    if pendingDeletes.contains(key) { return nil }
    if let queued = pending[key] { return queued }
    return readFromDisk(key: key)
  }

  public func store(
    pullRequestID: String,
    headRefOid: String,
    preview: ReviewFilePreview
  ) {
    let key = Self.makeKey(
      pullRequestID: pullRequestID,
      headRefOid: headRefOid,
      path: preview.path,
      lineLimit: preview.lineLimit
    )
    pending[key] = preview
    pendingDeletes.remove(key)
    scheduleFlush()
  }

  public func remove(
    pullRequestID: String,
    headRefOid: String,
    path: String,
    lineLimit: UInt32
  ) {
    let key = Self.makeKey(
      pullRequestID: pullRequestID,
      headRefOid: headRefOid,
      path: path,
      lineLimit: lineLimit
    )
    pending.removeValue(forKey: key)
    pendingDeletes.insert(key)
    scheduleFlush()
  }

  public func clear() {
    pending.removeAll()
    pendingDeletes.removeAll()
    flushTask?.cancel()
    flushTask = nil
    guard fileManager.fileExists(atPath: directory.path) else { return }
    if let contents = try? fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    ) {
      for url in contents {
        try? fileManager.removeItem(at: url)
      }
    }
  }

  public func flushPending() async {
    if let task = flushTask {
      await task.value
    }
    if !pending.isEmpty || !pendingDeletes.isEmpty {
      await runFlush()
    }
  }

  public func currentDiskBytes() -> Int {
    diskEntries().reduce(0) { $0 + $1.size }
  }

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
        try? fileManager.removeItem(at: fileURL(forKey: key))
      }
      for (key, preview) in pending {
        do {
          let data = try Self.encoder.encode(preview)
          try data.write(to: fileURL(forKey: key), options: .atomic)
        } catch {
          HarnessMonitorLogger.store.warning(
            """
            ReviewFilePreviewStore flush failed; \
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
        ReviewFilePreviewStore directory create failed; \
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
    for entry in entries.sorted(by: { $0.mtime < $1.mtime }) where totalBytes > diskCapBytes {
      do {
        try fileManager.removeItem(at: entry.url)
        totalBytes -= entry.size
      } catch {
        HarnessMonitorLogger.store.warning(
          """
          ReviewFilePreviewStore LRU evict failed; \
          path=\(entry.url.path, privacy: .public) \
          error=\(String(reflecting: error), privacy: .public)
          """
        )
      }
    }
  }

  private func readFromDisk(key: String) -> ReviewFilePreview? {
    let url = fileURL(forKey: key)
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    do {
      let data = try Data(contentsOf: url)
      let preview = try Self.decoder.decode(ReviewFilePreview.self, from: data)
      try? fileManager.setAttributes([.modificationDate: Date.now], ofItemAtPath: url.path)
      return preview
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
      guard let values = try? url.resourceValues(forKeys: Set(keys)),
        let size = values.fileSize,
        let mtime = values.contentModificationDate
      else {
        return nil
      }
      return DiskEntry(url: url, size: size, mtime: mtime)
    }
  }

  private func fileURL(forKey key: String) -> URL {
    directory.appendingPathComponent("\(key).json", isDirectory: false)
  }

  static func makeKey(
    pullRequestID: String,
    headRefOid: String,
    path: String,
    lineLimit: UInt32
  ) -> String {
    let raw = "\(pullRequestID)\u{1F}\(headRefOid)\u{1F}\(path)\u{1F}\(lineLimit)"
    let digest = SHA256.hash(data: Data(raw.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}
