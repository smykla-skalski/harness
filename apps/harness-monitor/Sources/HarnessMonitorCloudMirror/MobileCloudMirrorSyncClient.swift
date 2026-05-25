import Foundation
import HarnessMonitorCore
import HarnessMonitorCrypto

public enum MobileCloudMirrorSyncError: Error, Equatable, Sendable {
  case missingSnapshotEnvelope(String)
  case staleSnapshot(Date)
  case commandAlreadyReceipted(String)
  case cannotCancelCommandStatus(commandID: String, status: MobileCommandStatus)
  case cannotCancelOtherDeviceCommand(commandID: String)
}

public struct MobileQueuedCommand: Equatable, Sendable {
  public var signedCommand: MobileSignedCommand
  public var record: MobileMirrorRecord

  public init(signedCommand: MobileSignedCommand, record: MobileMirrorRecord) {
    self.signedCommand = signedCommand
    self.record = record
  }
}

public enum MobileCloudMirrorRecordAAD {
  public static func data(for metadata: MobileMirrorRecordMetadata) -> Data {
    [
      "id=\(metadata.id)",
      "type=\(metadata.type.rawValue)",
      "stationID=\(metadata.stationID)",
      "schemaVersion=\(metadata.schemaVersion)",
      "revision=\(metadata.revision)",
      "tombstone=\(metadata.tombstone)",
    ]
    .joined(separator: "\n")
    .data(using: .utf8) ?? Data()
  }
}

public actor MobileCloudMirrorSyncClient {
  let database: any MobileCloudMirrorDatabase
  let cipher: MobilePayloadCipher
  let deviceIdentity: MobileDeviceIdentity
  let actorDeviceID: String
  private let commandKeyID: String
  private let retention: TimeInterval

  public init(
    database: any MobileCloudMirrorDatabase,
    cipher: MobilePayloadCipher,
    deviceIdentity: MobileDeviceIdentity,
    actorDeviceID: String? = nil,
    commandKeyID: String,
    retention: TimeInterval = MobileCloudMirrorSchema.sevenDayRetention
  ) {
    self.database = database
    self.cipher = cipher
    self.deviceIdentity = deviceIdentity
    self.actorDeviceID = actorDeviceID ?? deviceIdentity.id
    self.commandKeyID = commandKeyID
    self.retention = retention
  }

  public func fetchLatestSnapshot(
    stationID: String,
    now: Date = .now
  ) async throws -> MobileMirrorSnapshot? {
    var directSnapshotStaleExpiresAt: Date?
    do {
      if let directSnapshot = try await fetchDirectDeviceSnapshot(stationID: stationID, now: now) {
        return directSnapshot
      }
    } catch MobileCloudMirrorSyncError.staleSnapshot(let expiresAt) {
      directSnapshotStaleExpiresAt = expiresAt
    }

    let records = try await database.fetchAll(stationID: stationID)
    let snapshotRecords =
      records
      .filter { $0.metadata.type == .snapshot && !$0.metadata.tombstone }
      .sorted(by: isNewer)
    guard let newestRecord = snapshotRecords.first else {
      if let directSnapshotStaleExpiresAt {
        throw MobileCloudMirrorSyncError.staleSnapshot(directSnapshotStaleExpiresAt)
      }
      return nil
    }
    let activeRecords = snapshotRecords.filter { $0.metadata.expiresAt > now }
    guard !activeRecords.isEmpty else {
      throw MobileCloudMirrorSyncError.staleSnapshot(
        directSnapshotStaleExpiresAt ?? newestRecord.metadata.expiresAt
      )
    }

    for record in activeRecords {
      guard
        let snapshot = try openSnapshotRecord(
          record,
          allRecords: records,
          now: now
        )
      else {
        continue
      }
      return snapshot.mergingMobileCommandRecords(
        commands: decryptableCommandRecords(in: records, stationID: stationID, now: now),
        receipts: decryptableReceiptRecords(in: records, stationID: stationID, now: now),
        now: now
      )
    }
    return nil
  }

  public func queueCommand(
    _ command: MobileCommandRecord,
    currentRevision: Int64,
    now: Date = .now
  ) async throws -> MobileQueuedCommand {
    var queuedCommand = command
    queuedCommand.status = .queued
    queuedCommand.actorDeviceID = actorDeviceID
    queuedCommand.updatedAt = now
    let validatedCommand =
      try queuedCommand
      .validatingForQueue(now: now)
      .validatingFreshState(currentRevision: currentRevision)

    let signedCommand = try MobileCommandSigner.sign(
      command: validatedCommand,
      identity: deviceIdentity,
      signedAt: now
    )
    let metadata = MobileMirrorRecordMetadata(
      id: validatedCommand.id,
      type: .command,
      stationID: validatedCommand.stationID,
      revision: currentRevision,
      updatedAt: now,
      expiresAt: now.addingTimeInterval(retention)
    )
    let envelope = try cipher.seal(
      signedCommand,
      keyID: commandKeyID,
      additionalAuthenticatedData: MobileCloudMirrorRecordAAD.data(for: metadata),
      createdAt: now
    )
    let record = MobileMirrorRecord(metadata: metadata, envelope: envelope)
    try await database.save(record)
    return MobileQueuedCommand(signedCommand: signedCommand, record: record)
  }

  @discardableResult
  public func cancelCommand(
    _ command: MobileCommandRecord,
    currentRevision: Int64,
    now: Date = .now
  ) async throws -> MobileCommandReceipt {
    guard canCancelCommandFromThisActor(command) else {
      throw MobileCloudMirrorSyncError.cannotCancelOtherDeviceCommand(commandID: command.id)
    }
    guard command.status == .queued else {
      throw MobileCloudMirrorSyncError.cannotCancelCommandStatus(
        commandID: command.id,
        status: command.status
      )
    }
    guard !command.isExpired(now: now) else {
      throw MobileCommandValidationError.expired
    }
    if try await hasAnyReceiptRecord(
      forCommandID: command.id,
      stationID: command.stationID,
      now: now
    ) {
      throw MobileCloudMirrorSyncError.commandAlreadyReceipted(command.id)
    }

    let receiptID = Self.receiptRecordID(forCommandID: command.id)
    let receipt = MobileCommandReceipt(
      commandID: command.id,
      stationID: command.stationID,
      status: .cancelled,
      message: "Cancelled by \(deviceIdentity.displayName).",
      receivedAt: now,
      completedAt: now,
      executionRevision: currentRevision
    )
    let metadata = MobileMirrorRecordMetadata(
      id: receiptID,
      type: .receipt,
      stationID: command.stationID,
      revision: currentRevision,
      updatedAt: now,
      expiresAt: now.addingTimeInterval(retention)
    )
    let envelope = try cipher.seal(
      receipt,
      keyID: commandKeyID,
      additionalAuthenticatedData: MobileCloudMirrorRecordAAD.data(for: metadata),
      createdAt: now
    )
    try await database.save(MobileMirrorRecord(metadata: metadata, envelope: envelope))
    return receipt
  }

  nonisolated private static func receiptRecordID(forCommandID commandID: String) -> String {
    "receipt-\(commandID)"
  }

  nonisolated private static func receiptRecordIDs(forCommandID commandID: String) -> [String] {
    var recordIDs: [String] = []
    for status in MobileCommandStatus.allCases where status != .draft && status != .queued {
      let terminalReceiptID = receiptRecordID(forCommandID: commandID)
      let recordID =
        status.isTerminal
        ? terminalReceiptID
        : "\(terminalReceiptID)-\(status.rawValue)"
      guard !recordIDs.contains(recordID) else {
        continue
      }
      recordIDs.append(recordID)
    }
    return recordIDs
  }

  private func hasAnyReceiptRecord(
    forCommandID commandID: String,
    stationID: String,
    now: Date
  ) async throws -> Bool {
    for recordID in Self.receiptRecordIDs(forCommandID: commandID) {
      guard let record = try await database.fetch(recordID: recordID),
        record.metadata.type == .receipt,
        record.metadata.stationID == stationID,
        !record.metadata.tombstone,
        record.metadata.expiresAt > now
      else {
        continue
      }
      return true
    }
    return false
  }

  nonisolated private func isNewer(
    _ lhs: MobileMirrorRecord,
    _ rhs: MobileMirrorRecord
  ) -> Bool {
    if lhs.metadata.revision != rhs.metadata.revision {
      return lhs.metadata.revision > rhs.metadata.revision
    }
    return lhs.metadata.updatedAt > rhs.metadata.updatedAt
  }
}
