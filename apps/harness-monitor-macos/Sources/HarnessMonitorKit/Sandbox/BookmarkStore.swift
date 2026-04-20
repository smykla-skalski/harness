import Foundation
import os

/// Persists security-scoped bookmarks so the app remembers user-authorized folders.
///
/// Assumes a single Swift writer per bookmark file; the Rust daemon reads the file but
/// does not mutate it. Two concurrent Monitor app instances sharing the same app-group
/// container will race on writes (last-writer-wins); callers should serialize upstream.
public actor BookmarkStore {
  public static let mruCap = 20
  public static let logger = Logger(subsystem: "io.harnessmonitor", category: "sandbox")

  public struct ResolvedScope: Sendable {
    public let url: URL
    public let isStale: Bool
  }

  private let storeFile: URL
  private var cached: PersistedStore?

  public init(containerURL: URL) {
    self.storeFile = SandboxPaths.bookmarksFileURL(containerURL: containerURL)
    try? FileManager.default.createDirectory(
      at: storeFile.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
  }

  public func all() -> [Record] {
    (try? loadAndValidate().bookmarks) ?? []
  }

  public func loadAndValidate() throws -> PersistedStore {
    if let cached { return cached }
    guard FileManager.default.fileExists(atPath: storeFile.path) else {
      let fresh = PersistedStore()
      cached = fresh
      return fresh
    }
    let data: Data
    do {
      data = try Data(contentsOf: storeFile)
    } catch {
      throw BookmarkStoreError.ioError(String(describing: error))
    }
    let decoded = try Self.decoder.decode(PersistedStore.self, from: data)
    if decoded.schemaVersion != PersistedStore.currentSchemaVersion {
      throw BookmarkStoreError.unsupportedSchemaVersion(
        found: decoded.schemaVersion,
        expected: PersistedStore.currentSchemaVersion
      )
    }
    cached = decoded
    return decoded
  }

  public func add(url: URL, kind: Record.Kind) throws -> Record {
    let bookmark = try url.bookmarkData(
      options: .withSecurityScope,
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
    var store = try loadForMutation()
    let record = Record(
      kind: kind,
      displayName: url.lastPathComponent,
      lastResolvedPath: url.path,
      bookmarkData: bookmark
    )
    store.bookmarks.insert(record, at: 0)
    if store.bookmarks.count > Self.mruCap {
      store.bookmarks.removeLast(store.bookmarks.count - Self.mruCap)
    }
    try save(store)
    return record
  }

  public func remove(id: String) throws {
    var store = try loadForMutation()
    store.bookmarks.removeAll { $0.id == id }
    try save(store)
  }

  public func touch(id: String) throws {
    var store = try loadForMutation()
    guard let idx = store.bookmarks.firstIndex(where: { $0.id == id }) else {
      throw BookmarkStoreError.notFound(id: id)
    }
    var rec = store.bookmarks.remove(at: idx)
    rec.lastAccessedAt = .now
    store.bookmarks.insert(rec, at: 0)
    try save(store)
  }

  public func resolve(id: String) throws -> ResolvedScope {
    var store = try loadForMutation()
    guard let idx = store.bookmarks.firstIndex(where: { $0.id == id }) else {
      throw BookmarkStoreError.notFound(id: id)
    }
    var record = store.bookmarks[idx]
    var isStale = false
    let url: URL
    do {
      url = try URL(
        resolvingBookmarkData: record.bookmarkData,
        options: .withSecurityScope,
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )
    } catch {
      throw BookmarkStoreError.unresolvable(id: id, underlying: String(describing: error))
    }
    if isStale {
      record.staleCount += 1
      Self.logger.warning(
        "refreshing stale bookmark id=\(id, privacy: .public) count=\(record.staleCount)")
      let refreshed = try url.bookmarkData(
        options: .withSecurityScope,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      record.bookmarkData = refreshed
    }
    record.lastResolvedPath = url.path
    record.lastAccessedAt = .now
    store.bookmarks[idx] = record
    try save(store)
    return ResolvedScope(url: url, isStale: isStale)
  }

  /// Loads the store for a mutating operation. Unlike `all()`, every error
  /// propagates so a write never silently clobbers a future-schema file or a
  /// file we could not read. A missing file is the one acceptable start-fresh
  /// case and is detected at the filesystem level rather than by parsing
  /// error messages.
  private func loadForMutation() throws -> PersistedStore {
    guard FileManager.default.fileExists(atPath: storeFile.path) else {
      return PersistedStore()
    }
    return try loadAndValidate()
  }

  private func save(_ store: PersistedStore) throws {
    let data = try Self.encoder.encode(store)
    let tmp = storeFile.deletingLastPathComponent()
      .appendingPathComponent("bookmarks.json.tmp-\(UUID().uuidString)")
    do {
      try data.write(to: tmp, options: .atomic)
      _ = try FileManager.default.replaceItemAt(storeFile, withItemAt: tmp)
    } catch {
      try? FileManager.default.removeItem(at: tmp)
      Self.logger.error("bookmarks save failed: \(String(describing: error), privacy: .public)")
      throw BookmarkStoreError.ioError(String(describing: error))
    }
    cached = store
  }

  private static let decoder: JSONDecoder = {
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601
    return dec
  }()

  private static let encoder: JSONEncoder = {
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    return enc
  }()

  #if DEBUG
    /// Inserts a record directly without generating real bookmark data.
    ///
    /// Only available in DEBUG builds. Intended exclusively for UI-test preseed
    /// scenarios where the real `.fileImporter` flow must be bypassed.
    public func insertForTesting(_ record: Record) throws {
      var store = try loadForMutation()
      store.bookmarks.insert(record, at: 0)
      if store.bookmarks.count > Self.mruCap {
        store.bookmarks.removeLast(store.bookmarks.count - Self.mruCap)
      }
      try save(store)
    }
  #endif
}
