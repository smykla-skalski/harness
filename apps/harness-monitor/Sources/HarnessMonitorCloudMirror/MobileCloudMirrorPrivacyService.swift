import Foundation
import HarnessMonitorCore

public struct MobileCloudMirrorRecordInventory: Codable, Equatable, Sendable {
  public var totalRecordCount: Int
  public var encryptedRecordCount: Int
  public var tombstoneRecordCount: Int
  public var expiredRecordCount: Int
  public var encryptedPayloadByteCount: Int
  public var recordCountsByType: [String: Int]
  public var recordCountsByStation: [String: Int]
  public var earliestExpiresAt: Date?
  public var latestExpiresAt: Date?
  public var clearMetadataKeys: [String]
  public var encryptedEnvelopeKeys: [String]

  public init(
    records: [MobileMirrorRecord],
    now: Date,
    clearMetadataKeys: [String] = MobileCloudMirrorSchema.metadataKeys,
    encryptedEnvelopeKeys: [String] = MobileCloudMirrorSchema.encryptedEnvelopeKeys
  ) {
    totalRecordCount = records.count
    encryptedRecordCount = records.count { $0.envelope != nil }
    tombstoneRecordCount = records.count { $0.metadata.tombstone }
    expiredRecordCount = records.count { $0.metadata.expiresAt <= now }
    encryptedPayloadByteCount = records.reduce(0) { partial, record in
      guard let envelope = record.envelope else {
        return partial
      }
      return partial
        + envelope.nonce.count
        + envelope.ciphertext.count
        + envelope.tag.count
        + envelope.additionalAuthenticatedData.count
    }
    recordCountsByType = Self.countsByType(records)
    recordCountsByStation = Self.countsByStation(records)
    earliestExpiresAt = records.map(\.metadata.expiresAt).min()
    latestExpiresAt = records.map(\.metadata.expiresAt).max()
    self.clearMetadataKeys = clearMetadataKeys
    self.encryptedEnvelopeKeys = encryptedEnvelopeKeys
  }

  private static func countsByType(_ records: [MobileMirrorRecord]) -> [String: Int] {
    records.reduce(into: [:]) { counts, record in
      counts[record.metadata.type.rawValue, default: 0] += 1
    }
  }

  private static func countsByStation(_ records: [MobileMirrorRecord]) -> [String: Int] {
    records.reduce(into: [:]) { counts, record in
      counts[record.metadata.stationID, default: 0] += 1
    }
  }
}

public struct MobileCloudMirrorExportArchive: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var generatedAt: Date
  public var stationID: String
  public var stationIDs: [String]
  public var inventory: MobileCloudMirrorRecordInventory
  public var records: [MobileMirrorRecord]

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case generatedAt
    case stationID
    case stationIDs
    case inventory
    case records
  }

  public init(
    schemaVersion: Int = 2,
    generatedAt: Date,
    stationID: String,
    records: [MobileMirrorRecord]
  ) {
    self.schemaVersion = schemaVersion
    self.generatedAt = generatedAt
    self.stationID = stationID
    self.stationIDs = [stationID]
    inventory = MobileCloudMirrorRecordInventory(records: records, now: generatedAt)
    self.records = records
  }

  public init(
    schemaVersion: Int = 2,
    generatedAt: Date,
    stationIDs: [String],
    records: [MobileMirrorRecord]
  ) {
    let stationIDs = stationIDs.deduplicatedPreservingOrder()
    self.schemaVersion = schemaVersion
    self.generatedAt = generatedAt
    self.stationIDs = stationIDs
    self.stationID = stationIDs.count == 1 ? stationIDs[0] : "multiple"
    inventory = MobileCloudMirrorRecordInventory(records: records, now: generatedAt)
    self.records = records
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    generatedAt = try container.decode(Date.self, forKey: .generatedAt)
    stationID = try container.decode(String.self, forKey: .stationID)
    stationIDs =
      try container.decodeIfPresent([String].self, forKey: .stationIDs)
      ?? [stationID]
    records = try container.decode([MobileMirrorRecord].self, forKey: .records)
    inventory =
      try container.decodeIfPresent(MobileCloudMirrorRecordInventory.self, forKey: .inventory)
      ?? MobileCloudMirrorRecordInventory(records: records, now: generatedAt)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(generatedAt, forKey: .generatedAt)
    try container.encode(stationID, forKey: .stationID)
    try container.encode(stationIDs, forKey: .stationIDs)
    try container.encode(inventory, forKey: .inventory)
    try container.encode(records, forKey: .records)
  }

  public func encodedData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(self)
  }
}

public struct MobileCloudMirrorDeletionReport: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var deletedAt: Date
  public var stationIDs: [String]
  public var inventory: MobileCloudMirrorRecordInventory

  public var deletedRecordCount: Int {
    inventory.totalRecordCount
  }

  public init(
    schemaVersion: Int = 1,
    deletedAt: Date,
    stationIDs: [String],
    records: [MobileMirrorRecord]
  ) {
    self.schemaVersion = schemaVersion
    self.deletedAt = deletedAt
    self.stationIDs = stationIDs.deduplicatedPreservingOrder()
    inventory = MobileCloudMirrorRecordInventory(records: records, now: deletedAt)
  }
}

public protocol MobileCloudMirrorPrivacyManaging: Sendable {
  func exportArchive(stationID: String, now: Date) async throws -> MobileCloudMirrorExportArchive
  func exportArchive(stationIDs: [String], now: Date) async throws -> MobileCloudMirrorExportArchive
  func exportRecords(stationID: String, now: Date) async throws -> Data
  func exportRecords(stationIDs: [String], now: Date) async throws -> Data
  func deleteRecordReport(stationID: String, now: Date) async throws
    -> MobileCloudMirrorDeletionReport
  func deleteRecordReport(stationIDs: [String], now: Date) async throws
    -> MobileCloudMirrorDeletionReport
  func deleteRecords(stationID: String) async throws -> Int
  func deleteRecords(stationIDs: [String]) async throws -> Int
}

public actor MobileCloudMirrorPrivacyService: MobileCloudMirrorPrivacyManaging {
  private let database: any MobileCloudMirrorDatabase

  public init(database: any MobileCloudMirrorDatabase) {
    self.database = database
  }

  public func exportArchive(
    stationID: String,
    now: Date = .now
  ) async throws -> MobileCloudMirrorExportArchive {
    try await exportArchive(stationIDs: [stationID], now: now)
  }

  public func exportArchive(
    stationIDs: [String],
    now: Date = .now
  ) async throws -> MobileCloudMirrorExportArchive {
    let stationIDs = stationIDs.deduplicatedPreservingOrder()
    let records = try await records(for: stationIDs)
      .sorted(by: recordSort)
    return MobileCloudMirrorExportArchive(
      generatedAt: now,
      stationIDs: stationIDs,
      records: records
    )
  }

  public func exportRecords(stationID: String, now: Date = .now) async throws -> Data {
    try await exportRecords(stationIDs: [stationID], now: now)
  }

  public func exportRecords(stationIDs: [String], now: Date = .now) async throws -> Data {
    try await exportArchive(stationIDs: stationIDs, now: now).encodedData()
  }

  public func deleteRecordReport(
    stationID: String,
    now: Date = .now
  ) async throws -> MobileCloudMirrorDeletionReport {
    try await deleteRecordReport(stationIDs: [stationID], now: now)
  }

  public func deleteRecordReport(
    stationIDs: [String],
    now: Date = .now
  ) async throws -> MobileCloudMirrorDeletionReport {
    let stationIDs = stationIDs.deduplicatedPreservingOrder()
    let records = try await records(for: stationIDs)
      .sorted(by: recordSort)
    for record in records {
      try await database.delete(recordID: record.id)
    }
    return MobileCloudMirrorDeletionReport(
      deletedAt: now,
      stationIDs: stationIDs,
      records: records
    )
  }

  public func deleteRecords(stationID: String) async throws -> Int {
    try await deleteRecords(stationIDs: [stationID])
  }

  public func deleteRecords(stationIDs: [String]) async throws -> Int {
    try await deleteRecordReport(stationIDs: stationIDs, now: .now).deletedRecordCount
  }

  private func records(for stationIDs: [String]) async throws -> [MobileMirrorRecord] {
    var records: [MobileMirrorRecord] = []
    for stationID in stationIDs {
      records.append(contentsOf: try await database.fetchAll(stationID: stationID))
    }
    return records
  }

  nonisolated private func recordSort(
    _ lhs: MobileMirrorRecord,
    _ rhs: MobileMirrorRecord
  ) -> Bool {
    if lhs.metadata.revision != rhs.metadata.revision {
      return lhs.metadata.revision > rhs.metadata.revision
    }
    return lhs.metadata.updatedAt > rhs.metadata.updatedAt
  }
}

extension Array where Element == String {
  fileprivate func deduplicatedPreservingOrder() -> Self {
    var seen: Set<String> = []
    var result: [String] = []
    for value in self {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, seen.insert(trimmed).inserted else {
        continue
      }
      result.append(trimmed)
    }
    return result
  }
}
