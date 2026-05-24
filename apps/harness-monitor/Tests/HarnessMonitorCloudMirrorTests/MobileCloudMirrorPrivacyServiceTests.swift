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
    XCTAssertEqual(archive.generatedAt, now)
    XCTAssertEqual(archive.records.map(\.id), ["snapshot-a", "command-a"])
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

extension JSONDecoder {
  fileprivate static var iso8601: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
