import CloudKit
import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import XCTest

final class MobileCloudMirrorCloudKitTests: XCTestCase {
  func testCloudKitRecordContainsOnlyClearMetadataAndOpaqueEnvelope() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let mirrorRecord = MobileMirrorRecord(
      metadata: MobileMirrorRecordMetadata(
        id: "snapshot-station-a",
        type: .snapshot,
        stationID: "station-a",
        revision: 42,
        updatedAt: now,
        expiresAt: now.addingTimeInterval(60),
        chunkIDs: ["chunk-1"]
      ),
      envelope: MobileEncryptedEnvelope(
        keyID: "station-key",
        nonce: Data([1, 2, 3]),
        ciphertext: Data("encrypted snapshot body".utf8),
        tag: Data([4, 5, 6]),
        additionalAuthenticatedData: Data("metadata".utf8),
        createdAt: now
      )
    )

    let record = MobileCloudMirrorCKRecordCodec.encode(mirrorRecord)
    let decoded = try MobileCloudMirrorCKRecordCodec.decode(record)

    XCTAssertEqual(decoded, mirrorRecord)
    XCTAssertEqual(record.recordType, MobileCloudMirrorCloudKitSchema.recordType)
    XCTAssertEqual(record[MobileCloudMirrorCloudKitSchema.Field.stationID] as? String, "station-a")
    XCTAssertEqual(
      record[MobileCloudMirrorCloudKitSchema.Field.envelopeCiphertext] as? Data,
      Data("encrypted snapshot body".utf8)
    )
    XCTAssertNil(record["title"])
    XCTAssertNil(record["status"])
    XCTAssertNil(record["transcript"])
    XCTAssertNil(record["diff"])
    XCTAssertNil(record["commandPayload"])
  }

  func testCloudKitRecordOmitsEmptyChunkIDsAndDecodesThemAsEmpty() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let mirrorRecord = MobileMirrorRecord(
      metadata: MobileMirrorRecordMetadata(
        id: "snapshot-station-a",
        type: .snapshot,
        stationID: "station-a",
        revision: 42,
        updatedAt: now,
        expiresAt: now.addingTimeInterval(60)
      ),
      envelope: MobileEncryptedEnvelope(
        keyID: "station-key",
        nonce: Data([1, 2, 3]),
        ciphertext: Data("encrypted snapshot body".utf8),
        tag: Data([4, 5, 6]),
        additionalAuthenticatedData: Data("metadata".utf8),
        createdAt: now
      )
    )

    let record = MobileCloudMirrorCKRecordCodec.encode(mirrorRecord)
    let decoded = try MobileCloudMirrorCKRecordCodec.decode(record)

    XCTAssertNil(record[MobileCloudMirrorCloudKitSchema.Field.chunkIDs])
    XCTAssertEqual(decoded.metadata.chunkIDs, [])
    XCTAssertEqual(decoded, mirrorRecord)
  }

  func testApplyingEmptyChunkIDsClearsExistingCloudKitField() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let record = CKRecord(
      recordType: MobileCloudMirrorCloudKitSchema.recordType,
      recordID: MobileCloudMirrorCKRecordCodec.recordID(for: "snapshot-station-a")
    )
    record[MobileCloudMirrorCloudKitSchema.Field.chunkIDs] = ["chunk-1"] as NSArray
    let mirrorRecord = MobileMirrorRecord(
      metadata: MobileMirrorRecordMetadata(
        id: "snapshot-station-a",
        type: .snapshot,
        stationID: "station-a",
        revision: 42,
        updatedAt: now,
        expiresAt: now.addingTimeInterval(60)
      ),
      envelope: nil
    )

    MobileCloudMirrorCKRecordCodec.apply(mirrorRecord, to: record)

    XCTAssertNil(record[MobileCloudMirrorCloudKitSchema.Field.chunkIDs])
  }

  func testUpsertRecordReusesExistingCloudKitRecordAndClearsOldFields() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let existing = CKRecord(
      recordType: MobileCloudMirrorCloudKitSchema.recordType,
      recordID: MobileCloudMirrorCKRecordCodec.recordID(for: "snapshot-station-a")
    )
    existing[MobileCloudMirrorCloudKitSchema.Field.revision] = 12 as NSNumber
    existing[MobileCloudMirrorCloudKitSchema.Field.chunkIDs] = ["old-chunk"] as NSArray
    existing[MobileCloudMirrorCloudKitSchema.Field.envelopeCiphertext] = Data("old".utf8) as NSData
    let mirrorRecord = MobileMirrorRecord(
      metadata: MobileMirrorRecordMetadata(
        id: "snapshot-station-a",
        type: .snapshot,
        stationID: "station-a",
        revision: 42,
        updatedAt: now,
        expiresAt: now.addingTimeInterval(60)
      ),
      envelope: nil
    )

    let record = MobileCloudMirrorCKRecordCodec.upsertRecord(mirrorRecord, existing: existing)

    XCTAssertTrue(record === existing)
    XCTAssertEqual(record.recordID.recordName, "snapshot-station-a")
    XCTAssertEqual(
      (record[MobileCloudMirrorCloudKitSchema.Field.revision] as? NSNumber)?.int64Value,
      42
    )
    XCTAssertNil(record[MobileCloudMirrorCloudKitSchema.Field.chunkIDs])
    XCTAssertNil(record[MobileCloudMirrorCloudKitSchema.Field.envelopeCiphertext])
  }

  func testCloudKitTombstoneHasMetadataButNoEnvelope() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let tombstone = MobileMirrorRecord(
      metadata: MobileMirrorRecordMetadata(
        id: "deleted-command",
        type: .tombstone,
        stationID: "station-a",
        revision: 43,
        updatedAt: now,
        expiresAt: now.addingTimeInterval(60),
        tombstone: true
      ),
      envelope: nil
    )

    let record = MobileCloudMirrorCKRecordCodec.encode(tombstone)
    let decoded = try MobileCloudMirrorCKRecordCodec.decode(record)

    XCTAssertEqual(decoded, tombstone)
    XCTAssertEqual(record[MobileCloudMirrorCloudKitSchema.Field.tombstone] as? Bool, true)
    XCTAssertNil(record[MobileCloudMirrorCloudKitSchema.Field.envelopeCiphertext])
  }

  func testZoneSubscriptionUsesMirrorZoneAndSilentPush() {
    let subscription = MobileCloudMirrorSubscriptionFactory().makeZoneSubscription()

    XCTAssertEqual(subscription.zoneID.zoneName, MobileCloudMirrorSchema.zoneName)
    XCTAssertEqual(subscription.subscriptionID, MobileCloudMirrorCloudKitSchema.subscriptionID)
    XCTAssertEqual(subscription.notificationInfo?.shouldSendContentAvailable, true)
  }

  func testMissingMirrorRecordTypeClassifierMatchesCloudKitServerMessage() {
    let missingType = CKError(
      .unknownItem,
      userInfo: [
        NSLocalizedDescriptionKey: "Did not find record type: MobileMirrorRecord"
      ]
    )
    let missingRecord = CKError(
      .unknownItem,
      userInfo: [
        NSLocalizedDescriptionKey: "Record not found"
      ]
    )

    XCTAssertTrue(MobileCloudMirrorCloudKitSchema.isMissingMirrorRecordType(missingType))
    XCTAssertFalse(MobileCloudMirrorCloudKitSchema.isMissingMirrorRecordType(missingRecord))
  }
}
