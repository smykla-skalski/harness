import CloudKit
import Foundation
import HarnessMonitorCore

public enum MobileCloudMirrorCKRecordCodec {
  public static func recordID(
    for recordID: String,
    zoneID: CKRecordZone.ID = MobileCloudMirrorCloudKitSchema.zoneID
  ) -> CKRecord.ID {
    CKRecord.ID(recordName: recordID, zoneID: zoneID)
  }

  public static func encode(
    _ mirrorRecord: MobileMirrorRecord,
    zoneID: CKRecordZone.ID = MobileCloudMirrorCloudKitSchema.zoneID
  ) -> CKRecord {
    upsertRecord(mirrorRecord, existing: nil, zoneID: zoneID)
  }

  public static func upsertRecord(
    _ mirrorRecord: MobileMirrorRecord,
    existing: CKRecord?,
    zoneID: CKRecordZone.ID = MobileCloudMirrorCloudKitSchema.zoneID
  ) -> CKRecord {
    let record =
      existing
      ?? CKRecord(
        recordType: MobileCloudMirrorCloudKitSchema.recordType,
        recordID: recordID(for: mirrorRecord.id, zoneID: zoneID)
      )
    apply(mirrorRecord, to: record)
    return record
  }

  public static func apply(_ mirrorRecord: MobileMirrorRecord, to record: CKRecord) {
    let metadata = mirrorRecord.metadata
    record[MobileCloudMirrorCloudKitSchema.Field.mirrorRecordType] =
      metadata.type.rawValue as NSString
    record[MobileCloudMirrorCloudKitSchema.Field.stationID] = metadata.stationID as NSString
    record[MobileCloudMirrorCloudKitSchema.Field.schemaVersion] = metadata.schemaVersion as NSNumber
    record[MobileCloudMirrorCloudKitSchema.Field.revision] = metadata.revision as NSNumber
    record[MobileCloudMirrorCloudKitSchema.Field.updatedAt] = metadata.updatedAt as NSDate
    record[MobileCloudMirrorCloudKitSchema.Field.expiresAt] = metadata.expiresAt as NSDate
    record[MobileCloudMirrorCloudKitSchema.Field.tombstone] = metadata.tombstone as NSNumber
    if metadata.chunkIDs.isEmpty {
      record[MobileCloudMirrorCloudKitSchema.Field.chunkIDs] = nil
    } else {
      record[MobileCloudMirrorCloudKitSchema.Field.chunkIDs] = metadata.chunkIDs as NSArray
    }

    guard let envelope = mirrorRecord.envelope else {
      clearEnvelopeFields(in: record)
      return
    }

    record[MobileCloudMirrorCloudKitSchema.Field.envelopeAlgorithm] =
      envelope.algorithm as NSString
    record[MobileCloudMirrorCloudKitSchema.Field.envelopeKeyID] = envelope.keyID as NSString
    record[MobileCloudMirrorCloudKitSchema.Field.envelopeNonce] = envelope.nonce as NSData
    record[MobileCloudMirrorCloudKitSchema.Field.envelopeCiphertext] =
      envelope.ciphertext as NSData
    record[MobileCloudMirrorCloudKitSchema.Field.envelopeTag] = envelope.tag as NSData
    record[MobileCloudMirrorCloudKitSchema.Field.envelopeAdditionalAuthenticatedData] =
      envelope.additionalAuthenticatedData as NSData
    record[MobileCloudMirrorCloudKitSchema.Field.envelopeCreatedAt] =
      envelope.createdAt as NSDate
  }

  public static func decode(_ record: CKRecord) throws -> MobileMirrorRecord {
    let type = try string(record, MobileCloudMirrorCloudKitSchema.Field.mirrorRecordType)
    guard let recordType = MobileMirrorRecordType(rawValue: type) else {
      throw MobileCloudMirrorCloudKitError.invalidField(
        "\(MobileCloudMirrorCloudKitSchema.Field.mirrorRecordType)=\(type)"
      )
    }

    let metadata = MobileMirrorRecordMetadata(
      id: record.recordID.recordName,
      type: recordType,
      stationID: try string(record, MobileCloudMirrorCloudKitSchema.Field.stationID),
      schemaVersion: try int(record, MobileCloudMirrorCloudKitSchema.Field.schemaVersion),
      revision: try int64(record, MobileCloudMirrorCloudKitSchema.Field.revision),
      updatedAt: try date(record, MobileCloudMirrorCloudKitSchema.Field.updatedAt),
      expiresAt: try date(record, MobileCloudMirrorCloudKitSchema.Field.expiresAt),
      tombstone: try bool(record, MobileCloudMirrorCloudKitSchema.Field.tombstone),
      chunkIDs: try stringArray(record, MobileCloudMirrorCloudKitSchema.Field.chunkIDs)
    )

    return MobileMirrorRecord(metadata: metadata, envelope: try decodeEnvelope(from: record))
  }

  private static func decodeEnvelope(from record: CKRecord) throws -> MobileEncryptedEnvelope? {
    guard
      record[MobileCloudMirrorCloudKitSchema.Field.envelopeCiphertext] != nil
        || record[MobileCloudMirrorCloudKitSchema.Field.envelopeNonce] != nil
    else {
      return nil
    }

    return MobileEncryptedEnvelope(
      algorithm: try string(record, MobileCloudMirrorCloudKitSchema.Field.envelopeAlgorithm),
      keyID: try string(record, MobileCloudMirrorCloudKitSchema.Field.envelopeKeyID),
      nonce: try data(record, MobileCloudMirrorCloudKitSchema.Field.envelopeNonce),
      ciphertext: try data(record, MobileCloudMirrorCloudKitSchema.Field.envelopeCiphertext),
      tag: try data(record, MobileCloudMirrorCloudKitSchema.Field.envelopeTag),
      additionalAuthenticatedData: try data(
        record,
        MobileCloudMirrorCloudKitSchema.Field.envelopeAdditionalAuthenticatedData
      ),
      createdAt: try date(record, MobileCloudMirrorCloudKitSchema.Field.envelopeCreatedAt)
    )
  }

  private static func clearEnvelopeFields(in record: CKRecord) {
    record[MobileCloudMirrorCloudKitSchema.Field.envelopeAlgorithm] = nil
    record[MobileCloudMirrorCloudKitSchema.Field.envelopeKeyID] = nil
    record[MobileCloudMirrorCloudKitSchema.Field.envelopeNonce] = nil
    record[MobileCloudMirrorCloudKitSchema.Field.envelopeCiphertext] = nil
    record[MobileCloudMirrorCloudKitSchema.Field.envelopeTag] = nil
    record[MobileCloudMirrorCloudKitSchema.Field.envelopeAdditionalAuthenticatedData] = nil
    record[MobileCloudMirrorCloudKitSchema.Field.envelopeCreatedAt] = nil
  }

  private static func string(_ record: CKRecord, _ key: String) throws -> String {
    guard let value = record[key] as? String else {
      throw MobileCloudMirrorCloudKitError.missingField(key)
    }
    return value
  }

  private static func int(_ record: CKRecord, _ key: String) throws -> Int {
    guard let value = record[key] as? NSNumber else {
      throw MobileCloudMirrorCloudKitError.missingField(key)
    }
    return value.intValue
  }

  private static func int64(_ record: CKRecord, _ key: String) throws -> Int64 {
    guard let value = record[key] as? NSNumber else {
      throw MobileCloudMirrorCloudKitError.missingField(key)
    }
    return value.int64Value
  }

  private static func bool(_ record: CKRecord, _ key: String) throws -> Bool {
    guard let value = record[key] as? NSNumber else {
      throw MobileCloudMirrorCloudKitError.missingField(key)
    }
    return value.boolValue
  }

  private static func date(_ record: CKRecord, _ key: String) throws -> Date {
    guard let value = record[key] as? Date else {
      throw MobileCloudMirrorCloudKitError.missingField(key)
    }
    return value
  }

  private static func data(_ record: CKRecord, _ key: String) throws -> Data {
    guard let value = record[key] as? Data else {
      throw MobileCloudMirrorCloudKitError.missingField(key)
    }
    return value
  }

  private static func stringArray(_ record: CKRecord, _ key: String) throws -> [String] {
    guard record[key] != nil else {
      return []
    }
    guard let value = record[key] as? [String] else {
      throw MobileCloudMirrorCloudKitError.missingField(key)
    }
    return value
  }
}
