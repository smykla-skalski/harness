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

  func testDecodeUnknownRecordTypeErrorIncludesOffendingValue() {
    let record = MobileCloudMirrorCKRecordCodec.encode(makeMirrorRecord(id: "x", type: .snapshot))
    record[MobileCloudMirrorCloudKitSchema.Field.mirrorRecordType] =
      "totally-unknown-kind" as NSString

    XCTAssertThrowsError(try MobileCloudMirrorCKRecordCodec.decode(record)) { error in
      guard case let MobileCloudMirrorCloudKitError.invalidField(detail) = error else {
        return XCTFail("expected invalidField, got \(error)")
      }
      XCTAssertTrue(
        detail.contains(MobileCloudMirrorCloudKitSchema.Field.mirrorRecordType),
        "error should name the field, got \(detail)"
      )
      XCTAssertTrue(
        detail.contains("totally-unknown-kind"),
        "error should carry the offending value for diagnosis, got \(detail)"
      )
    }
  }

  func testDecodeMatchResultsSkipsRecordsWithUnknownType() throws {
    let good1 = MobileCloudMirrorCKRecordCodec.encode(makeMirrorRecord(id: "good-1", type: .snapshot))
    let bogus = MobileCloudMirrorCKRecordCodec.encode(makeMirrorRecord(id: "mystery", type: .snapshot))
    bogus[MobileCloudMirrorCloudKitSchema.Field.mirrorRecordType] = "future-kind" as NSString
    let good2 = MobileCloudMirrorCKRecordCodec.encode(makeMirrorRecord(id: "good-2", type: .command))
    let results: [(CKRecord.ID, Result<CKRecord, any Error>)] = [
      (good1.recordID, .success(good1)),
      (bogus.recordID, .success(bogus)),
      (good2.recordID, .success(good2)),
    ]

    let decoded = try MobileCloudMirrorCKRecordCodec.decodeMatchResults(results)

    XCTAssertEqual(decoded.map(\.id), ["good-1", "good-2"])
  }

  func testDecodeMatchResultsSkipsRecordsMissingRequiredFields() throws {
    let good = MobileCloudMirrorCKRecordCodec.encode(makeMirrorRecord(id: "good", type: .snapshot))
    let malformed = MobileCloudMirrorCKRecordCodec.encode(
      makeMirrorRecord(id: "malformed", type: .snapshot)
    )
    malformed[MobileCloudMirrorCloudKitSchema.Field.stationID] = nil
    let results: [(CKRecord.ID, Result<CKRecord, any Error>)] = [
      (good.recordID, .success(good)),
      (malformed.recordID, .success(malformed)),
    ]

    let decoded = try MobileCloudMirrorCKRecordCodec.decodeMatchResults(results)

    XCTAssertEqual(decoded.map(\.id), ["good"])
  }

  func testDecodeMatchResultsPropagatesUnderlyingFetchFailure() {
    let underlying = NSError(domain: "test", code: 7)
    let results: [(CKRecord.ID, Result<CKRecord, any Error>)] = [
      (MobileCloudMirrorCKRecordCodec.recordID(for: "x"), .failure(underlying))
    ]

    XCTAssertThrowsError(try MobileCloudMirrorCKRecordCodec.decodeMatchResults(results)) { error in
      guard case MobileCloudMirrorCloudKitError.partialFailure = error else {
        return XCTFail("expected partialFailure, got \(error)")
      }
    }
  }

  func testDecodeMatchResultsMapsMissingRecordTypeToSchemaUnavailable() {
    let missingType = CKError(
      .unknownItem,
      userInfo: [NSLocalizedDescriptionKey: "Did not find record type: MobileMirrorRecord"]
    )
    let results: [(CKRecord.ID, Result<CKRecord, any Error>)] = [
      (MobileCloudMirrorCKRecordCodec.recordID(for: "x"), .failure(missingType))
    ]

    XCTAssertThrowsError(try MobileCloudMirrorCKRecordCodec.decodeMatchResults(results)) { error in
      guard case MobileCloudMirrorCloudKitError.schemaUnavailable = error else {
        return XCTFail("expected schemaUnavailable, got \(error)")
      }
    }
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

  private func makeMirrorRecord(
    id: String,
    type: MobileMirrorRecordType,
    stationID: String = "station-a",
    now: Date = Date(timeIntervalSince1970: 1_700_000_000)
  ) -> MobileMirrorRecord {
    MobileMirrorRecord(
      metadata: MobileMirrorRecordMetadata(
        id: id,
        type: type,
        stationID: stationID,
        revision: 1,
        updatedAt: now,
        expiresAt: now.addingTimeInterval(60)
      ),
      envelope: MobileEncryptedEnvelope(
        keyID: "station-key",
        nonce: Data([1, 2, 3]),
        ciphertext: Data("body".utf8),
        tag: Data([4, 5, 6]),
        additionalAuthenticatedData: Data("metadata".utf8),
        createdAt: now
      )
    )
  }
}
