import Foundation

public enum MobileSharedSnapshotStoreError: Error, Equatable, Sendable {
  case appGroupUnavailable(String)
}

public struct MobileSharedSnapshotArchive: Codable, Equatable, Sendable {
  public var snapshot: MobileMirrorSnapshot
  public var savedAt: Date

  public init(snapshot: MobileMirrorSnapshot, savedAt: Date) {
    self.snapshot = snapshot
    self.savedAt = savedAt
  }
}

public struct MobileSharedSnapshotStore: Sendable {
  public static let defaultAppGroupIdentifier = "group.io.harnessmonitor"

  private let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public init?(
    appGroupIdentifier: String = Self.defaultAppGroupIdentifier,
    fileManager: FileManager = .default
  ) {
    guard
      let containerURL = fileManager.containerURL(
        forSecurityApplicationGroupIdentifier: appGroupIdentifier
      )
    else {
      return nil
    }
    self.init(fileURL: Self.snapshotFileURL(in: containerURL))
  }

  public func save(_ snapshot: MobileMirrorSnapshot, savedAt: Date = .now) throws {
    let archive = MobileSharedSnapshotArchive(snapshot: snapshot, savedAt: savedAt)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(archive)
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(to: fileURL, options: [.atomic])
  }

  public func loadArchive() throws -> MobileSharedSnapshotArchive? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return nil
    }
    let data = try Data(contentsOf: fileURL)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(MobileSharedSnapshotArchive.self, from: data)
  }

  public func loadSnapshot(now: Date = .now) throws -> MobileMirrorSnapshot? {
    guard let archive = try loadArchive() else {
      return nil
    }
    guard archive.snapshot.expiresAt > now else {
      return nil
    }
    return archive.snapshot
  }

  public func loadLatestSnapshot() throws -> MobileMirrorSnapshot? {
    try loadArchive()?.snapshot
  }

  public func clear() throws {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return
    }
    try FileManager.default.removeItem(at: fileURL)
  }

  private static func snapshotFileURL(in containerURL: URL) -> URL {
    containerURL
      .appendingPathComponent("MobileWidgets", isDirectory: true)
      .appendingPathComponent("latest-snapshot.json")
  }
}
