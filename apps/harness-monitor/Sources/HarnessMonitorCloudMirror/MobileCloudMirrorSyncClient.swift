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
  private let database: any MobileCloudMirrorDatabase
  private let cipher: MobilePayloadCipher
  private let deviceIdentity: MobileDeviceIdentity
  private let commandKeyID: String
  private let retention: TimeInterval

  public init(
    database: any MobileCloudMirrorDatabase,
    cipher: MobilePayloadCipher,
    deviceIdentity: MobileDeviceIdentity,
    commandKeyID: String,
    retention: TimeInterval = MobileCloudMirrorSchema.sevenDayRetention
  ) {
    self.database = database
    self.cipher = cipher
    self.deviceIdentity = deviceIdentity
    self.commandKeyID = commandKeyID
    self.retention = retention
  }

  public func fetchLatestSnapshot(
    stationID: String,
    now: Date = .now
  ) async throws -> MobileMirrorSnapshot? {
    let records = try await database.fetchAll(stationID: stationID)
    let snapshotRecords =
      records
      .filter { $0.metadata.type == .snapshot && !$0.metadata.tombstone }
      .sorted(by: isNewer)
    guard let newestRecord = snapshotRecords.first else {
      return nil
    }
    let activeRecords = snapshotRecords.filter { $0.metadata.expiresAt > now }
    guard !activeRecords.isEmpty else {
      throw MobileCloudMirrorSyncError.staleSnapshot(newestRecord.metadata.expiresAt)
    }

    for record in activeRecords {
      guard let envelope = record.envelope else {
        throw MobileCloudMirrorSyncError.missingSnapshotEnvelope(record.id)
      }
      guard let snapshot: MobileMirrorSnapshot = try? cipher.open(envelope),
        snapshot.expiresAt > now
      else {
        continue
      }
      return snapshot.mergingMobileCommandRecords(
        commands: decryptableCommandRecords(in: records, now: now),
        receipts: decryptableReceiptRecords(in: records, now: now),
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
    queuedCommand.actorDeviceID = deviceIdentity.id
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
    guard command.actorDeviceID == deviceIdentity.id else {
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
    let receiptID = Self.receiptRecordID(forCommandID: command.id)
    if try await database.fetch(recordID: receiptID) != nil {
      throw MobileCloudMirrorSyncError.commandAlreadyReceipted(command.id)
    }

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

  private nonisolated static func receiptRecordID(forCommandID commandID: String) -> String {
    "receipt-\(commandID)"
  }

  private nonisolated func isNewer(
    _ lhs: MobileMirrorRecord,
    _ rhs: MobileMirrorRecord
  ) -> Bool {
    if lhs.metadata.revision != rhs.metadata.revision {
      return lhs.metadata.revision > rhs.metadata.revision
    }
    return lhs.metadata.updatedAt > rhs.metadata.updatedAt
  }

  private func decryptableCommandRecords(
    in records: [MobileMirrorRecord],
    now: Date
  ) -> [MobileCommandRecord] {
    records
      .filter {
        $0.metadata.type == .command
          && !$0.metadata.tombstone
          && $0.metadata.expiresAt > now
      }
      .compactMap(decryptableCommand)
  }

  private func decryptableCommand(_ record: MobileMirrorRecord) -> MobileCommandRecord? {
    guard let signingKeyFingerprint = try? deviceIdentity.signingKeyFingerprint(),
      let signingPublicKey = try? deviceIdentity.signingPublicKeyRawRepresentation()
    else {
      return nil
    }
    guard let envelope = record.envelope,
      let signedCommand: MobileSignedCommand = try? cipher.open(envelope),
      signedCommand.command.actorDeviceID == deviceIdentity.id,
      signedCommand.signingKeyFingerprint == signingKeyFingerprint,
      (try? MobileCommandSigner.verify(
        signedCommand,
        publicKeyRawRepresentation: signingPublicKey
      )) == true
    else {
      return nil
    }
    return signedCommand.command
  }

  private func decryptableReceiptRecords(
    in records: [MobileMirrorRecord],
    now: Date
  ) -> [MobileCommandReceipt] {
    records
      .filter {
        $0.metadata.type == .receipt
          && !$0.metadata.tombstone
          && $0.metadata.expiresAt > now
      }
      .compactMap { record in
        guard let envelope = record.envelope else {
          return nil
        }
        return try? cipher.open(envelope, as: MobileCommandReceipt.self)
      }
  }
}

extension MobileMirrorSnapshot {
  fileprivate func mergingMobileCommandRecords(
    commands: [MobileCommandRecord],
    receipts: [MobileCommandReceipt],
    now: Date
  ) -> Self {
    guard !commands.isEmpty || !receipts.isEmpty else {
      return self
    }
    var merged = self
    var commandsByID = Dictionary(uniqueKeysWithValues: merged.commands.map { ($0.id, $0) })
    var commandOrder = merged.commands.map(\.id)
    for command in commands {
      if commandsByID[command.id] == nil {
        commandOrder.append(command.id)
      }
      commandsByID[command.id] = command.updatingExpiredStatus(now: now)
    }
    for receipt in receipts {
      guard var command = commandsByID[receipt.commandID] else {
        continue
      }
      command.status = receipt.status
      command.receipt = receipt
      command.updatedAt = receipt.completedAt ?? receipt.receivedAt
      commandsByID[receipt.commandID] = command
    }
    merged.commands = commandOrder.compactMap { commandID in
      commandsByID.removeValue(forKey: commandID)
    }
    if !commandsByID.isEmpty {
      merged.commands.append(
        contentsOf: commandsByID.values.sorted { lhs, rhs in
          if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
          }
          return lhs.id < rhs.id
        }
      )
    }
    return merged
  }
}

extension MobileCommandRecord {
  fileprivate func updatingExpiredStatus(now: Date) -> Self {
    guard isExpired(now: now), !status.isTerminal else {
      return self
    }
    var command = self
    command.status = .expired
    command.updatedAt = expiresAt
    return command
  }
}
