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

enum MobileCloudMirrorCloudKitClient {
  static let identifier = "iCloud.io.harnessmonitor"
  static let container = CKContainer(identifier: identifier)
  static let privateDatabase = container.privateCloudDatabase
}

public struct LiveMobileCloudMirrorDatabase: MobileCloudMirrorDatabase {
  // Retain both objects so CloudKit operations do not outlive a temporary client.
  private let container: CKContainer
  private let database: CKDatabase
  private let zoneID: CKRecordZone.ID
  private let subscriptionFactory: MobileCloudMirrorSubscriptionFactory
  private let zoneEnsurer: MobileCloudMirrorZoneEnsurer

  public init(
    zoneID: CKRecordZone.ID = MobileCloudMirrorCloudKitSchema.zoneID,
    subscriptionFactory: MobileCloudMirrorSubscriptionFactory =
      MobileCloudMirrorSubscriptionFactory()
  ) {
    self.init(
      container: MobileCloudMirrorCloudKitClient.container,
      database: MobileCloudMirrorCloudKitClient.privateDatabase,
      zoneID: zoneID,
      subscriptionFactory: subscriptionFactory
    )
  }

  public init(
    container: CKContainer,
    database: CKDatabase? = nil,
    zoneID: CKRecordZone.ID = MobileCloudMirrorCloudKitSchema.zoneID,
    subscriptionFactory: MobileCloudMirrorSubscriptionFactory =
      MobileCloudMirrorSubscriptionFactory()
  ) {
    let resolvedDatabase =
      database
      ?? (container === MobileCloudMirrorCloudKitClient.container
        ? MobileCloudMirrorCloudKitClient.privateDatabase
        : container.privateCloudDatabase)
    self.container = container
    self.database = resolvedDatabase
    self.zoneID = zoneID
    self.subscriptionFactory = subscriptionFactory
    self.zoneEnsurer = MobileCloudMirrorZoneEnsurer {
      do {
        _ = try await resolvedDatabase.save(CKRecordZone(zoneID: zoneID))
      } catch let error as CKError where error.code == .serverRejectedRequest {
        return
      } catch let error as CKError where error.code == .zoneBusy {
        return
      }
    }
  }

  public func save(_ record: MobileMirrorRecord) async throws {
    try await zoneEnsurer.ensureIfNeeded()
    try await saveUpsert(record)
  }

  private func saveUpsert(_ mirrorRecord: MobileMirrorRecord) async throws {
    let recordID = MobileCloudMirrorCKRecordCodec.recordID(for: mirrorRecord.id, zoneID: zoneID)
    var lastConflict: CKError?
    var conflictRecord: CKRecord?

    for _ in 0..<3 {
      do {
        let existingRecord: CKRecord?
        if let conflictRecord {
          existingRecord = conflictRecord
        } else {
          existingRecord = try await existingCloudRecord(recordID: recordID)
        }
        let cloudRecord = MobileCloudMirrorCKRecordCodec.upsertRecord(
          mirrorRecord,
          existing: existingRecord,
          zoneID: zoneID
        )
        _ = try await database.save(cloudRecord)
        return
      } catch let error as CKError where error.code == .serverRecordChanged {
        lastConflict = error
        conflictRecord = serverRecord(from: error)
        if conflictRecord == nil {
          try await Task.sleep(nanoseconds: 100_000_000)
        }
        continue
      } catch let error as CKError
        where MobileCloudMirrorCloudKitSchema.isMissingMirrorRecordType(error)
      {
        throw MobileCloudMirrorCloudKitError.schemaUnavailable(
          MobileCloudMirrorCloudKitSchema.recordType
        )
      }
    }

    if let lastConflict {
      throw lastConflict
    }
  }

  private func serverRecord(from error: CKError) -> CKRecord? {
    error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord
  }

  private func existingCloudRecord(recordID: CKRecord.ID) async throws -> CKRecord? {
    do {
      return try await database.record(for: recordID)
    } catch let error as CKError where error.code == .unknownItem {
      return nil
    } catch let error as CKError where error.code == .zoneNotFound {
      await zoneEnsurer.invalidate()
      try await zoneEnsurer.ensureIfNeeded()
      return nil
    }
  }

  public func fetch(recordID: String) async throws -> MobileMirrorRecord? {
    do {
      let record = try await database.record(
        for: MobileCloudMirrorCKRecordCodec.recordID(for: recordID, zoneID: zoneID)
      )
      return try MobileCloudMirrorCKRecordCodec.decode(record)
    } catch let error as MobileCloudMirrorCloudKitError where error.isSkippableDecodeFailure {
      return nil
    } catch let error as CKError where error.code == .unknownItem {
      return nil
    } catch let error as CKError where error.code == .zoneNotFound {
      await zoneEnsurer.invalidate()
      return nil
    }
  }

  public func fetchAll(stationID: String) async throws -> [MobileMirrorRecord] {
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
    } catch let error as CKError where error.code == .zoneNotFound {
      await zoneEnsurer.invalidate()
      return []
    } catch let error as CKError
      where MobileCloudMirrorCloudKitSchema.isMissingMirrorRecordType(error)
    {
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
    try await zoneEnsurer.ensureIfNeeded()
    _ = try await database.save(subscriptionFactory.makeZoneSubscription(zoneID: zoneID))
  }

  private func append(
    _ results: [(CKRecord.ID, Result<CKRecord, any Error>)],
    to decoded: inout [MobileMirrorRecord]
  ) throws {
    decoded.append(
      contentsOf: try MobileCloudMirrorCKRecordCodec.decodeMatchResults(results)
    )
  }
}
