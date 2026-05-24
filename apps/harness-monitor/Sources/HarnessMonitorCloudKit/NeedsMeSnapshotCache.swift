import Foundation

public protocol NeedsMeSnapshotCache: Sendable {
  func load() async -> NeedsMeSnapshot?
  func save(_ snapshot: NeedsMeSnapshot) async
}

public actor InMemoryNeedsMeSnapshotCache: NeedsMeSnapshotCache {
  private var stored: NeedsMeSnapshot?

  public init(initial: NeedsMeSnapshot? = nil) {
    stored = initial
  }

  public func load() async -> NeedsMeSnapshot? {
    stored
  }

  public func save(_ snapshot: NeedsMeSnapshot) async {
    stored = snapshot
  }
}

public struct FileNeedsMeSnapshotCache: NeedsMeSnapshotCache {
  public static let `default` = FileNeedsMeSnapshotCache()

  private let fileURL: URL

  public init(fileURL: URL = FileNeedsMeSnapshotCache.defaultFileURL()) {
    self.fileURL = fileURL
  }

  public static func defaultFileURL() -> URL {
    let base =
      FileManager.default
      .urls(for: .cachesDirectory, in: .userDomainMask)
      .first
      ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    return
      base
      .appendingPathComponent("io.harnessmonitor.cloudkit", isDirectory: true)
      .appendingPathComponent("needs-me-snapshot.json")
  }

  public func load() async -> NeedsMeSnapshot? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    guard let data = try? Data(contentsOf: fileURL) else { return nil }
    guard let dto = try? Self.decoder.decode(SnapshotDTO.self, from: data) else { return nil }
    return NeedsMeSnapshot(count: dto.count, updatedAt: dto.updatedAt, revision: dto.revision)
  }

  public func save(_ snapshot: NeedsMeSnapshot) async {
    let directory = fileURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let dto = SnapshotDTO(
      count: snapshot.count,
      updatedAt: snapshot.updatedAt,
      revision: snapshot.revision
    )
    guard let data = try? Self.encoder.encode(dto) else { return }
    try? data.write(to: fileURL, options: .atomic)
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()

  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()

  private struct SnapshotDTO: Codable {
    let count: Int64
    let updatedAt: Date
    let revision: Int64
  }
}
