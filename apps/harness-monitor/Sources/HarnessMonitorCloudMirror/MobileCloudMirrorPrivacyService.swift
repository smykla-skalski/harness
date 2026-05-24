import Foundation
import HarnessMonitorCore

public struct MobileCloudMirrorExportArchive: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var generatedAt: Date
  public var stationID: String
  public var records: [MobileMirrorRecord]

  public init(
    schemaVersion: Int = 1,
    generatedAt: Date,
    stationID: String,
    records: [MobileMirrorRecord]
  ) {
    self.schemaVersion = schemaVersion
    self.generatedAt = generatedAt
    self.stationID = stationID
    self.records = records
  }
}

public protocol MobileCloudMirrorPrivacyManaging: Sendable {
  func exportRecords(stationID: String, now: Date) async throws -> Data
  func deleteRecords(stationID: String) async throws -> Int
}

public actor MobileCloudMirrorPrivacyService: MobileCloudMirrorPrivacyManaging {
  private let database: any MobileCloudMirrorDatabase

  public init(database: any MobileCloudMirrorDatabase) {
    self.database = database
  }

  public func exportRecords(stationID: String, now: Date = .now) async throws -> Data {
    let records = try await database.fetchAll(stationID: stationID)
      .sorted(by: recordSort)
    let archive = MobileCloudMirrorExportArchive(
      generatedAt: now,
      stationID: stationID,
      records: records
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(archive)
  }

  public func deleteRecords(stationID: String) async throws -> Int {
    let records = try await database.fetchAll(stationID: stationID)
    for record in records {
      try await database.delete(recordID: record.id)
    }
    return records.count
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
