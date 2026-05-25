import Foundation
import HarnessMonitorCore

public enum MobileCloudMirrorError: Error, Equatable, Sendable {
  case missingRecord(String)
}

public enum MobileCloudMirrorSchema {
  public static let zoneName = "HarnessMonitorMirror"
  public static let sevenDayRetention: TimeInterval = 7 * 24 * 60 * 60
  public static let metadataKeys = [
    "recordType",
    "stationID",
    "schemaVersion",
    "revision",
    "updatedAt",
    "expiresAt",
    "tombstone",
    "chunkIDs",
  ]
}

public protocol MobileCloudMirrorDatabase: Sendable {
  func save(_ record: MobileMirrorRecord) async throws
  func fetch(recordID: String) async throws -> MobileMirrorRecord?
  func fetchAll(stationID: String) async throws -> [MobileMirrorRecord]
  func delete(recordID: String) async throws
}

public actor InMemoryMobileCloudMirrorDatabase: MobileCloudMirrorDatabase {
  private var records: [String: MobileMirrorRecord] = [:]

  public init(records: [MobileMirrorRecord] = []) {
    self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
  }

  public func save(_ record: MobileMirrorRecord) async throws {
    records[record.id] = record
  }

  public func fetch(recordID: String) async throws -> MobileMirrorRecord? {
    records[recordID]
  }

  public func fetchAll(stationID: String) async throws -> [MobileMirrorRecord] {
    records.values
      .filter { $0.metadata.stationID == stationID }
      .sorted { $0.metadata.updatedAt > $1.metadata.updatedAt }
  }

  public func delete(recordID: String) async throws {
    records.removeValue(forKey: recordID)
  }
}

public actor MobileCloudMirrorStore {
  private let database: any MobileCloudMirrorDatabase
  private let retention: TimeInterval

  public init(
    database: any MobileCloudMirrorDatabase,
    retention: TimeInterval = MobileCloudMirrorSchema.sevenDayRetention
  ) {
    self.database = database
    self.retention = retention
  }

  @discardableResult
  public func upsert(
    id: String,
    type: MobileMirrorRecordType,
    stationID: String,
    revision: Int64,
    envelope: MobileEncryptedEnvelope,
    now: Date = .now
  ) async throws -> MobileMirrorRecord {
    let record = MobileMirrorRecord(
      metadata: MobileMirrorRecordMetadata(
        id: id,
        type: type,
        stationID: stationID,
        revision: revision,
        updatedAt: now,
        expiresAt: now.addingTimeInterval(retention)
      ),
      envelope: envelope
    )
    try await database.save(record)
    return record
  }

  @discardableResult
  public func tombstone(
    recordID: String,
    stationID: String,
    revision: Int64,
    now: Date = .now
  ) async throws -> MobileMirrorRecord {
    let record = MobileMirrorRecord(
      metadata: MobileMirrorRecordMetadata(
        id: recordID,
        type: .tombstone,
        stationID: stationID,
        revision: revision,
        updatedAt: now,
        expiresAt: now.addingTimeInterval(retention),
        tombstone: true
      ),
      envelope: nil
    )
    try await database.save(record)
    return record
  }

  public func fetchActiveRecords(stationID: String, now: Date = .now) async throws
    -> [MobileMirrorRecord]
  {
    try await database.fetchAll(stationID: stationID)
      .filter { !$0.metadata.tombstone && $0.metadata.expiresAt > now }
  }

  public func pruneExpired(stationID: String, now: Date = .now) async throws -> Int {
    let records = try await database.fetchAll(stationID: stationID)
    let expired = records.filter { $0.metadata.expiresAt <= now }
    for record in expired {
      try await database.delete(recordID: record.id)
    }
    return expired.count
  }
}
