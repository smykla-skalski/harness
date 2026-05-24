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

  private func makeRecord(
    id: String,
    stationID: String,
    type: MobileMirrorRecordType = .snapshot,
    revision: Int64,
    now: Date
  ) -> MobileMirrorRecord {
    MobileMirrorRecord(
      metadata: MobileMirrorRecordMetadata(
        id: id,
        type: type,
        stationID: stationID,
        revision: revision,
        updatedAt: now.addingTimeInterval(TimeInterval(revision)),
        expiresAt: now.addingTimeInterval(60)
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
