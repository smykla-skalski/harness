import CloudKit
import Foundation
import HarnessMonitorCore

public enum MobileCloudMirrorCloudKitError: Error, Equatable, Sendable {
  case missingField(String)
  case invalidField(String)
  case partialFailure(String)
  case schemaUnavailable(String)
}

public enum MobileCloudMirrorCloudKitSchema {
  public static let recordType = "MobileMirrorRecord"
  public static let subscriptionID = "mobile-mirror-zone-changes"

  public enum Field {
    public static let mirrorRecordType = "mirrorRecordType"
    public static let stationID = "stationID"
    public static let schemaVersion = "schemaVersion"
    public static let revision = "revision"
    public static let updatedAt = "updatedAt"
    public static let expiresAt = "expiresAt"
    public static let tombstone = "tombstone"
    public static let chunkIDs = "chunkIDs"
    public static let envelopeAlgorithm = "envelopeAlgorithm"
    public static let envelopeKeyID = "envelopeKeyID"
    public static let envelopeNonce = "envelopeNonce"
    public static let envelopeCiphertext = "envelopeCiphertext"
    public static let envelopeTag = "envelopeTag"
    public static let envelopeAdditionalAuthenticatedData = "envelopeAAD"
    public static let envelopeCreatedAt = "envelopeCreatedAt"
  }

  public static var zoneID: CKRecordZone.ID {
    CKRecordZone.ID(zoneName: MobileCloudMirrorSchema.zoneName)
  }

  public static func isMissingMirrorRecordType(_ error: CKError) -> Bool {
    guard error.code == .unknownItem else {
      return false
    }
    let message = [
      error.localizedDescription,
      error.userInfo["ServerErrorDescription"] as? String,
      error.userInfo["CKErrorDescription"] as? String,
      error.userInfo[NSLocalizedDescriptionKey] as? String,
      error.userInfo[NSDebugDescriptionErrorKey] as? String,
    ]
    .compactMap(\.self)
    .joined(separator: "\n")
    return message.localizedCaseInsensitiveContains(recordType)
      && message.localizedCaseInsensitiveContains("record type")
  }
}

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
    let record = CKRecord(
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
    record[MobileCloudMirrorCloudKitSchema.Field.chunkIDs] = metadata.chunkIDs as NSArray

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
        MobileCloudMirrorCloudKitSchema.Field.mirrorRecordType
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
    guard let value = record[key] as? [String] else {
      throw MobileCloudMirrorCloudKitError.missingField(key)
    }
    return value
  }
}

public struct MobileCloudMirrorSubscriptionFactory: Sendable {
  public init() {}

  public func makeZoneSubscription(
    zoneID: CKRecordZone.ID = MobileCloudMirrorCloudKitSchema.zoneID
  ) -> CKRecordZoneSubscription {
    let subscription = CKRecordZoneSubscription(
      zoneID: zoneID,
      subscriptionID: MobileCloudMirrorCloudKitSchema.subscriptionID
    )
    let notificationInfo = CKSubscription.NotificationInfo()
    notificationInfo.shouldSendContentAvailable = true
    subscription.notificationInfo = notificationInfo
    return subscription
  }
}

public struct LiveMobileCloudMirrorDatabase: MobileCloudMirrorDatabase {
  private let database: CKDatabase
  private let zoneID: CKRecordZone.ID
  private let subscriptionFactory: MobileCloudMirrorSubscriptionFactory

  public init(
    database: CKDatabase = CKContainer(identifier: "iCloud.io.harnessmonitor").privateCloudDatabase,
    zoneID: CKRecordZone.ID = MobileCloudMirrorCloudKitSchema.zoneID,
    subscriptionFactory: MobileCloudMirrorSubscriptionFactory =
      MobileCloudMirrorSubscriptionFactory()
  ) {
    self.database = database
    self.zoneID = zoneID
    self.subscriptionFactory = subscriptionFactory
  }

  public func save(_ record: MobileMirrorRecord) async throws {
    try await ensureZone()
    let cloudRecord = MobileCloudMirrorCKRecordCodec.encode(record, zoneID: zoneID)
    do {
      _ = try await database.save(cloudRecord)
    } catch let error as CKError
      where MobileCloudMirrorCloudKitSchema.isMissingMirrorRecordType(error)
    {
      throw MobileCloudMirrorCloudKitError.schemaUnavailable(
        MobileCloudMirrorCloudKitSchema.recordType
      )
    }
  }

  public func fetch(recordID: String) async throws -> MobileMirrorRecord? {
    try await ensureZone()
    do {
      let record = try await database.record(
        for: MobileCloudMirrorCKRecordCodec.recordID(for: recordID, zoneID: zoneID)
      )
      return try MobileCloudMirrorCKRecordCodec.decode(record)
    } catch let error as CKError where error.code == .unknownItem {
      return nil
    } catch let error as CKError where error.code == .zoneNotFound {
      try await ensureZone()
      return nil
    }
  }

  public func fetchAll(stationID: String) async throws -> [MobileMirrorRecord] {
    try await ensureZone()
    let query = CKQuery(
      recordType: MobileCloudMirrorCloudKitSchema.recordType,
      predicate: NSPredicate(
        format: "%K == %@",
        MobileCloudMirrorCloudKitSchema.Field.stationID,
        stationID
      )
    )
    query.sortDescriptors = [
      NSSortDescriptor(key: MobileCloudMirrorCloudKitSchema.Field.updatedAt, ascending: false)
    ]

    var decoded: [MobileMirrorRecord] = []
    do {
      var response = try await database.records(
        matching: query,
        inZoneWith: zoneID,
        desiredKeys: nil,
        resultsLimit: CKQueryOperation.maximumResults
      )
      try append(response.matchResults, to: &decoded)

      while let cursor = response.queryCursor {
        response = try await database.records(
          continuingMatchFrom: cursor,
          desiredKeys: nil,
          resultsLimit: CKQueryOperation.maximumResults
        )
        try append(response.matchResults, to: &decoded)
      }
    } catch let error as CKError
      where error.code == .zoneNotFound
      || MobileCloudMirrorCloudKitSchema.isMissingMirrorRecordType(error)
    {
      try await ensureZone()
      return []
    } catch MobileCloudMirrorCloudKitError.schemaUnavailable {
      return []
    }

    return decoded.sorted { $0.metadata.updatedAt > $1.metadata.updatedAt }
  }

  public func delete(recordID: String) async throws {
    do {
      _ = try await database.deleteRecord(
        withID: MobileCloudMirrorCKRecordCodec.recordID(for: recordID, zoneID: zoneID)
      )
    } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
      return
    }
  }

  public func ensureSubscription() async throws {
    try await ensureZone()
    _ = try await database.save(subscriptionFactory.makeZoneSubscription(zoneID: zoneID))
  }

  private func ensureZone() async throws {
    do {
      _ = try await database.save(CKRecordZone(zoneID: zoneID))
    } catch let error as CKError where error.code == .serverRejectedRequest {
      return
    } catch let error as CKError where error.code == .zoneBusy {
      return
    }
  }

  private func append(
    _ results: [(CKRecord.ID, Result<CKRecord, any Error>)],
    to decoded: inout [MobileMirrorRecord]
  ) throws {
    for (_, result) in results {
      switch result {
      case .success(let record):
        decoded.append(try MobileCloudMirrorCKRecordCodec.decode(record))
      case .failure(let error as CKError)
      where MobileCloudMirrorCloudKitSchema.isMissingMirrorRecordType(error):
        throw MobileCloudMirrorCloudKitError.schemaUnavailable(
          MobileCloudMirrorCloudKitSchema.recordType
        )
      case .failure(let error):
        throw MobileCloudMirrorCloudKitError.partialFailure(String(describing: error))
      }
    }
  }
}
