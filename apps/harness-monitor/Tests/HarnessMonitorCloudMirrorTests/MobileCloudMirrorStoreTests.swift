import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import XCTest

final class MobileCloudMirrorStoreTests: XCTestCase {
  func testUpsertStoresOnlyMetadataAndOpaqueEnvelope() async throws {
    let database = InMemoryMobileCloudMirrorDatabase()
    let store = MobileCloudMirrorStore(database: database)
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let envelope = MobileEncryptedEnvelope(
      keyID: "key",
      nonce: Data([1, 2, 3]),
      ciphertext: Data("encrypted".utf8),
      tag: Data([4, 5, 6]),
      createdAt: now
    )

    let record = try await store.upsert(
      id: "snapshot",
      type: .snapshot,
      stationID: "station",
      revision: 7,
      envelope: envelope,
      now: now
    )

    XCTAssertEqual(record.metadata.type, .snapshot)
    XCTAssertEqual(record.metadata.stationID, "station")
    XCTAssertEqual(record.envelope?.ciphertext, Data("encrypted".utf8))
    XCTAssertEqual(MobileCloudMirrorSchema.metadataKeys.contains("stationID"), true)
  }

  func testPruneDeletesExpiredRecordsAfterRetention() async throws {
    let database = InMemoryMobileCloudMirrorDatabase()
    let store = MobileCloudMirrorStore(database: database, retention: 10)
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let envelope = MobileEncryptedEnvelope(
      keyID: "key",
      nonce: Data([1]),
      ciphertext: Data([2]),
      tag: Data([3]),
      createdAt: now
    )

    try await store.upsert(
      id: "snapshot",
      type: .snapshot,
      stationID: "station",
      revision: 1,
      envelope: envelope,
      now: now
    )

    let prunedCount = try await store.pruneExpired(
      stationID: "station",
      now: now.addingTimeInterval(11)
    )
    let activeRecords = try await store.fetchActiveRecords(
      stationID: "station",
      now: now.addingTimeInterval(11)
    )

    XCTAssertEqual(prunedCount, 1)
    XCTAssertEqual(activeRecords, [])
  }

  func testTombstoneHasNoEnvelope() async throws {
    let database = InMemoryMobileCloudMirrorDatabase()
    let store = MobileCloudMirrorStore(database: database)

    let tombstone = try await store.tombstone(
      recordID: "deleted-command",
      stationID: "station",
      revision: 3
    )

    XCTAssertTrue(tombstone.metadata.tombstone)
    XCTAssertNil(tombstone.envelope)
  }
}
