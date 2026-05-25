import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import XCTest

final class MobileCloudMirrorPrivacyServiceTests: XCTestCase {
  func testExportRecordsArchivesOnlySelectedStationRecords() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let database = InMemoryMobileCloudMirrorDatabase(records: [
      makeRecord(id: "snapshot-a", stationID: "station-a", revision: 2, now: now),
      makeRecord(id: "command-a", stationID: "station-a", type: .command, revision: 1, now: now),
      makeRecord(id: "snapshot-b", stationID: "station-b", revision: 3, now: now),
    ])
    let service = MobileCloudMirrorPrivacyService(database: database)

    let data = try await service.exportRecords(stationID: "station-a", now: now)
    let archive = try JSONDecoder.iso8601.decode(MobileCloudMirrorExportArchive.self, from: data)

    XCTAssertEqual(archive.stationID, "station-a")
    XCTAssertEqual(archive.stationIDs, ["station-a"])
    XCTAssertEqual(archive.generatedAt, now)
    XCTAssertEqual(archive.records.map(\.id), ["snapshot-a", "command-a"])
    XCTAssertEqual(archive.inventory.totalRecordCount, 2)
    XCTAssertEqual(archive.inventory.recordCountsByType["snapshot"], 1)
    XCTAssertEqual(archive.inventory.recordCountsByType["command"], 1)
    XCTAssertEqual(archive.inventory.recordCountsByStation["station-a"], 2)
    XCTAssertEqual(archive.inventory.encryptedRecordCount, 2)
    XCTAssertEqual(archive.inventory.tombstoneRecordCount, 0)
    XCTAssertEqual(archive.inventory.expiredRecordCount, 0)
    XCTAssertGreaterThan(archive.inventory.encryptedPayloadByteCount, 0)
    XCTAssertEqual(archive.inventory.clearMetadataKeys, MobileCloudMirrorSchema.metadataKeys)
    XCTAssertEqual(
      archive.inventory.encryptedEnvelopeKeys,
      MobileCloudMirrorSchema.encryptedEnvelopeKeys
    )
  }

  func testExportArchiveDecodesLegacySingleStationShape() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let legacyArchive = LegacyMobileCloudMirrorExportArchive(
      generatedAt: now,
      stationID: "station-a",
      records: [
        makeRecord(id: "snapshot-a", stationID: "station-a", revision: 2, now: now)
      ]
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(legacyArchive)

    let archive = try JSONDecoder.iso8601.decode(MobileCloudMirrorExportArchive.self, from: data)

    XCTAssertEqual(archive.stationID, "station-a")
    XCTAssertEqual(archive.stationIDs, ["station-a"])
    XCTAssertEqual(archive.records.map(\.id), ["snapshot-a"])
    XCTAssertEqual(archive.inventory.totalRecordCount, 1)
    XCTAssertEqual(archive.inventory.recordCountsByType["snapshot"], 1)
  }

  func testExportRecordsArchivesAllRequestedStations() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let database = InMemoryMobileCloudMirrorDatabase(records: [
      makeRecord(id: "snapshot-a", stationID: "station-a", revision: 2, now: now),
      makeRecord(id: "command-a", stationID: "station-a", type: .command, revision: 1, now: now),
      makeRecord(id: "snapshot-b", stationID: "station-b", revision: 3, now: now),
      makeRecord(id: "snapshot-c", stationID: "station-c", revision: 4, now: now),
    ])
    let service = MobileCloudMirrorPrivacyService(database: database)

    let data = try await service.exportRecords(
      stationIDs: ["station-a", "station-b", "station-a"],
      now: now
    )
    let archive = try JSONDecoder.iso8601.decode(MobileCloudMirrorExportArchive.self, from: data)

    XCTAssertEqual(archive.stationID, "multiple")
    XCTAssertEqual(archive.stationIDs, ["station-a", "station-b"])
    XCTAssertEqual(archive.records.map(\.id), ["snapshot-b", "snapshot-a", "command-a"])
    XCTAssertEqual(archive.inventory.totalRecordCount, 3)
    XCTAssertEqual(archive.inventory.recordCountsByStation, ["station-a": 2, "station-b": 1])
  }

  func testExportArchiveIncludesDirectSnapshotRecordsWhenStationQueryIsEmpty()
    async throws
  {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let parent = makeRecord(
      id: "snapshot-direct",
      stationID: "station-a",
      revision: 7,
      now: now,
      chunkIDs: ["snapshot-direct-chunk-0"]
    )
    let chunk = makeRecord(
      id: "snapshot-direct-chunk-0",
      stationID: "station-a",
      type: .snapshotChunk,
      revision: 7,
      now: now
    )
    let otherStationRecord = makeRecord(
      id: "snapshot-direct-other",
      stationID: "station-b",
      revision: 8,
      now: now
    )
    let database = DirectOnlyPrivacyDatabase(records: [parent, chunk, otherStationRecord])
    let service = MobileCloudMirrorPrivacyService(database: database)

    let archive = try await service.exportArchive(
      stationIDs: [],
      directRecordIDs: [parent.id],
      now: now
    )

    XCTAssertEqual(archive.stationIDs, ["station-a"])
    XCTAssertEqual(archive.stationID, "station-a")
    XCTAssertEqual(Set(archive.records.map(\.id)), Set([parent.id, chunk.id]))
    XCTAssertEqual(archive.inventory.recordCountsByType["snapshot"], 1)
    XCTAssertEqual(archive.inventory.recordCountsByType["snapshotChunk"], 1)
  }

  func testDeleteRecordsRemovesOnlySelectedStationRecords() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let database = InMemoryMobileCloudMirrorDatabase(records: [
      makeRecord(id: "snapshot-a", stationID: "station-a", revision: 2, now: now),
      makeRecord(id: "snapshot-b", stationID: "station-b", revision: 3, now: now),
    ])
    let service = MobileCloudMirrorPrivacyService(database: database)

    let deletedCount = try await service.deleteRecords(stationID: "station-a")
    let stationARecords = try await database.fetchAll(stationID: "station-a")
    let stationBRecords = try await database.fetchAll(stationID: "station-b")

    XCTAssertEqual(deletedCount, 1)
    XCTAssertEqual(stationARecords, [])
    XCTAssertEqual(stationBRecords.map(\.id), ["snapshot-b"])
  }

  func testDeleteRecordReportSummarizesRemovedRecords() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let database = InMemoryMobileCloudMirrorDatabase(records: [
      makeRecord(id: "snapshot-a", stationID: "station-a", revision: 2, now: now),
      makeRecord(id: "command-a", stationID: "station-a", type: .command, revision: 1, now: now),
      makeRecord(id: "snapshot-b", stationID: "station-b", revision: 3, now: now),
      makeRecord(id: "snapshot-c", stationID: "station-c", revision: 4, now: now),
    ])
    let service = MobileCloudMirrorPrivacyService(database: database)

    let report = try await service.deleteRecordReport(
      stationIDs: ["station-a", "station-b", "station-a"],
      now: now
    )
    let stationARecords = try await database.fetchAll(stationID: "station-a")
    let stationBRecords = try await database.fetchAll(stationID: "station-b")
    let stationCRecords = try await database.fetchAll(stationID: "station-c")

    XCTAssertEqual(report.stationIDs, ["station-a", "station-b"])
    XCTAssertEqual(report.deletedAt, now)
    XCTAssertEqual(report.deletedRecordCount, 3)
    XCTAssertEqual(report.inventory.recordCountsByType["snapshot"], 2)
    XCTAssertEqual(report.inventory.recordCountsByType["command"], 1)
    XCTAssertEqual(report.inventory.recordCountsByStation, ["station-a": 2, "station-b": 1])
    XCTAssertEqual(stationARecords, [])
    XCTAssertEqual(stationBRecords, [])
    XCTAssertEqual(stationCRecords.map(\.id), ["snapshot-c"])
  }

  func testDeleteRecordReportRemovesDirectSnapshotRecordsWhenStationQueryIsEmpty()
    async throws
  {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let parent = makeRecord(
      id: "snapshot-direct",
      stationID: "station-a",
      revision: 7,
      now: now,
      chunkIDs: ["snapshot-direct-chunk-0"]
    )
    let chunk = makeRecord(
      id: "snapshot-direct-chunk-0",
      stationID: "station-a",
      type: .snapshotChunk,
      revision: 7,
      now: now
    )
    let database = DirectOnlyPrivacyDatabase(records: [parent, chunk])
    let service = MobileCloudMirrorPrivacyService(database: database)

    let report = try await service.deleteRecordReport(
      stationIDs: [],
      directRecordIDs: [parent.id],
      now: now
    )
    let remainingParent = try await database.fetch(recordID: parent.id)
    let remainingChunk = try await database.fetch(recordID: chunk.id)

    XCTAssertEqual(report.deletedRecordCount, 2)
    XCTAssertEqual(report.stationIDs, ["station-a"])
    XCTAssertEqual(report.inventory.recordCountsByType["snapshot"], 1)
    XCTAssertEqual(report.inventory.recordCountsByType["snapshotChunk"], 1)
    XCTAssertNil(remainingParent)
    XCTAssertNil(remainingChunk)
  }

  func testDeleteRecordsRemovesAllRequestedStations() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let database = InMemoryMobileCloudMirrorDatabase(records: [
      makeRecord(id: "snapshot-a", stationID: "station-a", revision: 2, now: now),
      makeRecord(id: "command-a", stationID: "station-a", type: .command, revision: 1, now: now),
      makeRecord(id: "snapshot-b", stationID: "station-b", revision: 3, now: now),
      makeRecord(id: "snapshot-c", stationID: "station-c", revision: 4, now: now),
    ])
    let service = MobileCloudMirrorPrivacyService(database: database)

    let deletedCount = try await service.deleteRecords(
      stationIDs: ["station-a", "station-b", "station-a"]
    )
    let stationARecords = try await database.fetchAll(stationID: "station-a")
    let stationBRecords = try await database.fetchAll(stationID: "station-b")
    let stationCRecords = try await database.fetchAll(stationID: "station-c")

    XCTAssertEqual(deletedCount, 3)
    XCTAssertEqual(stationARecords, [])
    XCTAssertEqual(stationBRecords, [])
    XCTAssertEqual(stationCRecords.map(\.id), ["snapshot-c"])
  }

  func testExportInventoryCountsExpiredAndTombstoneRecords() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let expired = MobileMirrorRecord(
      metadata: MobileMirrorRecordMetadata(
        id: "expired",
        type: .event,
        stationID: "station-a",
        revision: 1,
        updatedAt: now.addingTimeInterval(-120),
        expiresAt: now.addingTimeInterval(-60)
      ),
      envelope: MobileEncryptedEnvelope(
        keyID: "key",
        nonce: Data([1]),
        ciphertext: Data([2, 3]),
        tag: Data([4]),
        createdAt: now.addingTimeInterval(-120)
      )
    )
    let tombstone = MobileMirrorRecord(
      metadata: MobileMirrorRecordMetadata(
        id: "tombstone",
        type: .tombstone,
        stationID: "station-a",
        revision: 2,
        updatedAt: now,
        expiresAt: now.addingTimeInterval(60),
        tombstone: true
      ),
      envelope: nil
    )
    let database = InMemoryMobileCloudMirrorDatabase(records: [expired, tombstone])
    let service = MobileCloudMirrorPrivacyService(database: database)

    let archive = try await service.exportArchive(stationID: "station-a", now: now)

    XCTAssertEqual(archive.inventory.totalRecordCount, 2)
    XCTAssertEqual(archive.inventory.encryptedRecordCount, 1)
    XCTAssertEqual(archive.inventory.tombstoneRecordCount, 1)
    XCTAssertEqual(archive.inventory.expiredRecordCount, 1)
    XCTAssertEqual(archive.inventory.encryptedPayloadByteCount, 4)
    XCTAssertEqual(archive.inventory.recordCountsByType["event"], 1)
    XCTAssertEqual(archive.inventory.recordCountsByType["tombstone"], 1)
  }

  private func makeRecord(
    id: String,
    stationID: String,
    type: MobileMirrorRecordType = .snapshot,
    revision: Int64,
    now: Date,
    chunkIDs: [String] = []
  ) -> MobileMirrorRecord {
    MobileMirrorRecord(
      metadata: MobileMirrorRecordMetadata(
        id: id,
        type: type,
        stationID: stationID,
        revision: revision,
        updatedAt: now.addingTimeInterval(TimeInterval(revision)),
        expiresAt: now.addingTimeInterval(60),
        chunkIDs: chunkIDs
      ),
      envelope: MobileEncryptedEnvelope(
        keyID: "key",
        nonce: Data([1, 2, 3]),
        ciphertext: Data(id.utf8),
        tag: Data([4, 5, 6]),
        createdAt: now
      )
    )
  }
}

private actor DirectOnlyPrivacyDatabase: MobileCloudMirrorDatabase {
  private var records: [String: MobileMirrorRecord]

  init(records: [MobileMirrorRecord]) {
    self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
  }

  func save(_ record: MobileMirrorRecord) async throws {
    records[record.id] = record
  }

  func fetch(recordID: String) async throws -> MobileMirrorRecord? {
    records[recordID]
  }

  func fetchAll(stationID _: String) async throws -> [MobileMirrorRecord] {
    []
  }

  func delete(recordID: String) async throws {
    records.removeValue(forKey: recordID)
  }
}

private struct LegacyMobileCloudMirrorExportArchive: Encodable {
  var schemaVersion = 1
  var generatedAt: Date
  var stationID: String
  var records: [MobileMirrorRecord]
}

extension JSONDecoder {
  fileprivate static var iso8601: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
