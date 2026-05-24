import Foundation
import HarnessMonitorCore

public struct MobileCloudMirrorExportArchive: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var generatedAt: Date
  public var stationID: String
  public var stationIDs: [String]
  public var records: [MobileMirrorRecord]

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case generatedAt
    case stationID
    case stationIDs
    case records
  }

  public init(
    schemaVersion: Int = 1,
    generatedAt: Date,
    stationID: String,
    records: [MobileMirrorRecord]
  ) {
    self.schemaVersion = schemaVersion
    self.generatedAt = generatedAt
    self.stationID = stationID
    self.stationIDs = [stationID]
    self.records = records
  }

  public init(
    schemaVersion: Int = 1,
    generatedAt: Date,
    stationIDs: [String],
    records: [MobileMirrorRecord]
  ) {
    let stationIDs = stationIDs.deduplicatedPreservingOrder()
    self.schemaVersion = schemaVersion
    self.generatedAt = generatedAt
    self.stationIDs = stationIDs
    self.stationID = stationIDs.count == 1 ? stationIDs[0] : "multiple"
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
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(generatedAt, forKey: .generatedAt)
    try container.encode(stationID, forKey: .stationID)
    try container.encode(stationIDs, forKey: .stationIDs)
    try container.encode(records, forKey: .records)
  }
}

public protocol MobileCloudMirrorPrivacyManaging: Sendable {
  func exportRecords(stationID: String, now: Date) async throws -> Data
  func exportRecords(stationIDs: [String], now: Date) async throws -> Data
  func deleteRecords(stationID: String) async throws -> Int
  func deleteRecords(stationIDs: [String]) async throws -> Int
}

public actor MobileCloudMirrorPrivacyService: MobileCloudMirrorPrivacyManaging {
  private let database: any MobileCloudMirrorDatabase

  public init(database: any MobileCloudMirrorDatabase) {
    self.database = database
  }

  public func exportRecords(stationID: String, now: Date = .now) async throws -> Data {
    try await exportRecords(stationIDs: [stationID], now: now)
  }

  public func exportRecords(stationIDs: [String], now: Date = .now) async throws -> Data {
    let stationIDs = stationIDs.deduplicatedPreservingOrder()
    let records = try await records(for: stationIDs)
      .sorted(by: recordSort)
    let archive = MobileCloudMirrorExportArchive(
      generatedAt: now,
      stationIDs: stationIDs,
      records: records
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(archive)
  }

  public func deleteRecords(stationID: String) async throws -> Int {
    try await deleteRecords(stationIDs: [stationID])
  }

  public func deleteRecords(stationIDs: [String]) async throws -> Int {
    let stationIDs = stationIDs.deduplicatedPreservingOrder()
    let records = try await records(for: stationIDs)
    for record in records {
      try await database.delete(recordID: record.id)
    }
    return records.count
  }

  private func records(for stationIDs: [String]) async throws -> [MobileMirrorRecord] {
    var records: [MobileMirrorRecord] = []
    for stationID in stationIDs {
      records.append(contentsOf: try await database.fetchAll(stationID: stationID))
    }
    return records
  }

  private nonisolated func recordSort(
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
