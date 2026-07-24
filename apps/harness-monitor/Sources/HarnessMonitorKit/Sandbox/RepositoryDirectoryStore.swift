import Foundation
import os

public enum RepositoryDirectoryStoreError: Error, Equatable {
  case emptyRepository
  case unsupportedSchemaVersion(found: Int, expected: Int)
  case ioError(String)
}

/// Persists which local working directory backs each task-board repository, so a
/// GitHub-imported item delivers into the folder the user already picked instead
/// of re-prompting every time.
///
/// App-owned and app-local. The security-scoped bookmark itself lives in
/// `BookmarkStore`; this store only records the repository slug -> bookmark id
/// link. Keyed by a normalized `owner/repo` slug so items from the same
/// repository share one association. Assumes a single Swift writer, matching
/// `BookmarkStore`.
public actor RepositoryDirectoryStore {
  public static let logger = Logger(subsystem: "io.harnessmonitor", category: "sandbox")

  public struct Association: Codable, Sendable, Equatable, Identifiable {
    public let repository: String
    public let bookmarkID: String
    public var id: String { repository }

    public init(repository: String, bookmarkID: String) {
      self.repository = repository
      self.bookmarkID = bookmarkID
    }
  }

  struct PersistedStore: Codable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int = currentSchemaVersion
    var associations: [Association] = []
  }

  private let storeFile: URL
  private var cached: PersistedStore?

  public init(containerURL: URL) {
    self.storeFile = SandboxPaths.repositoryDirectoriesFileURL(containerURL: containerURL)
    try? FileManager.default.createDirectory(
      at: storeFile.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
  }

  /// Match the daemon's `normalize_repository_slug`: trim and lowercase so the
  /// same repository never splits into two associations.
  public static func normalizedRepository(_ repository: String) -> String {
    repository.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  public func bookmarkID(forRepository repository: String) -> String? {
    let key = Self.normalizedRepository(repository)
    guard !key.isEmpty else { return nil }
    return (try? loadValidated())?.associations.first { $0.repository == key }?.bookmarkID
  }

  public func allAssociations() -> [Association] {
    ((try? loadValidated())?.associations ?? []).sorted { $0.repository < $1.repository }
  }

  @discardableResult
  public func associate(repository: String, bookmarkID: String) throws -> Association {
    let key = Self.normalizedRepository(repository)
    guard !key.isEmpty else { throw RepositoryDirectoryStoreError.emptyRepository }
    var store = try loadValidated()
    store.associations.removeAll { $0.repository == key }
    let association = Association(repository: key, bookmarkID: bookmarkID)
    store.associations.append(association)
    try save(store)
    return association
  }

  public func removeAssociation(forRepository repository: String) throws {
    let key = Self.normalizedRepository(repository)
    var store = try loadValidated()
    let before = store.associations.count
    store.associations.removeAll { $0.repository == key }
    guard store.associations.count != before else { return }
    try save(store)
  }

  private func loadValidated() throws -> PersistedStore {
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
      throw RepositoryDirectoryStoreError.ioError(String(describing: error))
    }
    let decoded = try Self.decoder.decode(PersistedStore.self, from: data)
    guard decoded.schemaVersion == PersistedStore.currentSchemaVersion else {
      throw RepositoryDirectoryStoreError.unsupportedSchemaVersion(
        found: decoded.schemaVersion,
        expected: PersistedStore.currentSchemaVersion
      )
    }
    cached = decoded
    return decoded
  }

  private func save(_ store: PersistedStore) throws {
    let data: Data
    do {
      data = try Self.encoder.encode(store)
    } catch {
      throw RepositoryDirectoryStoreError.ioError(String(describing: error))
    }
    let tmp = storeFile.deletingLastPathComponent()
      .appendingPathComponent("repository-directories.json.tmp-\(UUID().uuidString)")
    do {
      try data.write(to: tmp, options: .atomic)
      _ = try FileManager.default.replaceItemAt(storeFile, withItemAt: tmp)
    } catch {
      try? FileManager.default.removeItem(at: tmp)
      Self.logger.error(
        "repository directory store save failed: \(String(describing: error), privacy: .public)"
      )
      throw RepositoryDirectoryStoreError.ioError(String(describing: error))
    }
    cached = store
  }

  private static let decoder = JSONDecoder()

  private static let encoder: JSONEncoder = {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    return enc
  }()
}
