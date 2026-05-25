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
  private let actorDeviceID: String
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
    if let directSnapshot = try await fetchDirectDeviceSnapshot(stationID: stationID, now: now) {
      return directSnapshot
    }

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

  private func fetchDirectDeviceSnapshot(
    stationID: String,
    now: Date
  ) async throws -> MobileMirrorSnapshot? {
    guard let recordID = try? directDeviceSnapshotRecordID(stationID: stationID),
      let record = try await database.fetch(recordID: recordID),
      record.metadata.type == .snapshot,
      !record.metadata.tombstone,
      record.metadata.stationID == stationID
    else {
      return nil
    }
    guard record.metadata.expiresAt > now else {
      throw MobileCloudMirrorSyncError.staleSnapshot(record.metadata.expiresAt)
    }

    let directRecords = try await directSnapshotRecords(for: record)
    guard
      let snapshot = try openSnapshotRecord(
        record,
        allRecords: directRecords,
        now: now
      )
    else {
      return nil
    }

    let stationRecords = (try? await database.fetchAll(stationID: stationID)) ?? []
    let mergeRecords = recordsByID(directRecords + stationRecords)
    return snapshot.mergingMobileCommandRecords(
      commands: decryptableCommandRecords(in: mergeRecords, stationID: stationID, now: now),
      receipts: decryptableReceiptRecords(in: mergeRecords, stationID: stationID, now: now),
      now: now
    )
  }

  private func directDeviceSnapshotRecordID(stationID: String) throws -> String {
    try MobileCloudMirrorSnapshotWriter.snapshotRecordID(
      stationID: stationID,
      deviceID: deviceIdentity.id,
      signingKeyFingerprint: deviceIdentity.signingKeyFingerprint()
    )
  }

  private func directSnapshotRecords(for record: MobileMirrorRecord) async throws
    -> [MobileMirrorRecord]
  {
    var records = [record]
    for chunkID in record.metadata.chunkIDs {
      guard let chunk = try await database.fetch(recordID: chunkID) else {
        continue
      }
      records.append(chunk)
    }
    return records
  }

  private func recordsByID(_ records: [MobileMirrorRecord]) -> [MobileMirrorRecord] {
    var orderedIDs: [String] = []
    var recordsByID: [String: MobileMirrorRecord] = [:]
    for record in records {
      if recordsByID[record.id] == nil {
        orderedIDs.append(record.id)
      }
      recordsByID[record.id] = record
    }
    return orderedIDs.compactMap { recordsByID[$0] }
  }

  private func openSnapshotRecord(
    _ record: MobileMirrorRecord,
    allRecords records: [MobileMirrorRecord],
    now: Date
  ) throws -> MobileMirrorSnapshot? {
    guard var envelope = record.envelope else {
      throw MobileCloudMirrorSyncError.missingSnapshotEnvelope(record.id)
    }
    guard
      envelope.additionalAuthenticatedData
        == MobileCloudMirrorRecordAAD.data(
          for: record.metadata
        )
    else {
      return nil
    }
    if !record.metadata.chunkIDs.isEmpty {
      guard let ciphertext = chunkedCiphertext(for: record, allRecords: records, now: now) else {
        return nil
      }
      envelope.ciphertext = ciphertext
    }
    guard let snapshot: MobileMirrorSnapshot = try? cipher.open(envelope),
      snapshot.expiresAt > now
    else {
      return nil
    }
    return snapshot
  }

  private func chunkedCiphertext(
    for snapshotRecord: MobileMirrorRecord,
    allRecords records: [MobileMirrorRecord],
    now: Date
  ) -> Data? {
    let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    var ciphertext = Data()
    for chunkID in snapshotRecord.metadata.chunkIDs {
      guard
        let chunk = recordsByID[chunkID],
        chunk.metadata.type == .snapshotChunk,
        chunk.metadata.stationID == snapshotRecord.metadata.stationID,
        chunk.metadata.revision == snapshotRecord.metadata.revision,
        !chunk.metadata.tombstone,
        chunk.metadata.expiresAt > now,
        let envelope = chunk.envelope
      else {
        return nil
      }
      ciphertext.append(envelope.ciphertext)
    }
    return ciphertext
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

  nonisolated private static func receiptRecordID(forCommandID commandID: String) -> String {
    "receipt-\(commandID)"
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

  private func decryptableCommandRecords(
    in records: [MobileMirrorRecord],
    stationID: String,
    now: Date
  ) -> [MobileCommandRecord] {
    records
      .filter {
        $0.metadata.type == .command
          && !$0.metadata.tombstone
          && $0.metadata.expiresAt > now
      }
      .compactMap { record in
        decryptableCommand(record, stationID: stationID)
      }
  }

  private func decryptableCommand(
    _ record: MobileMirrorRecord,
    stationID: String
  ) -> MobileCommandRecord? {
    guard let signingKeyFingerprint = try? deviceIdentity.signingKeyFingerprint(),
      let signingPublicKey = try? deviceIdentity.signingPublicKeyRawRepresentation()
    else {
      return nil
    }
    guard let envelope = record.envelope,
      envelope.additionalAuthenticatedData == MobileCloudMirrorRecordAAD.data(for: record.metadata),
      let signedCommand: MobileSignedCommand = try? cipher.open(envelope),
      isCommandReadableByThisDevice(signedCommand.command),
      signedCommand.signingKeyFingerprint == signingKeyFingerprint,
      (try? MobileCommandSigner.verify(
        signedCommand,
        publicKeyRawRepresentation: signingPublicKey
      )) == true
    else {
      return nil
    }
    guard signedCommand.command.stationID == stationID,
      signedCommand.command.id == record.id
    else {
      return nil
    }
    return signedCommand.command
  }

  private func isCommandReadableByThisDevice(_ command: MobileCommandRecord) -> Bool {
    command.actorDeviceID == actorDeviceID
      || MobileCommandActorDeviceID.isTrustedActor(
        command.actorDeviceID,
        for: deviceIdentity.id
      )
  }

  private func canCancelCommandFromThisActor(_ command: MobileCommandRecord) -> Bool {
    command.actorDeviceID == actorDeviceID
      || MobileCommandActorDeviceID.trustedBaseDeviceID(for: command.actorDeviceID)
        == MobileCommandActorDeviceID.trustedBaseDeviceID(for: actorDeviceID)
  }

  private func decryptableReceiptRecords(
    in records: [MobileMirrorRecord],
    stationID: String,
    now: Date
  ) -> [MobileCommandReceipt] {
    records
      .filter {
        $0.metadata.type == .receipt
          && !$0.metadata.tombstone
          && $0.metadata.expiresAt > now
      }
      .compactMap { record in
        guard let envelope = record.envelope,
          envelope.additionalAuthenticatedData
            == MobileCloudMirrorRecordAAD.data(
              for: record.metadata
            )
        else {
          return nil
        }
        guard let receipt = try? cipher.open(envelope, as: MobileCommandReceipt.self),
          receipt.stationID == stationID
        else {
          return nil
        }
        return receipt
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
    for receipt in receipts.sorted(by: oldestReceiptFirst) {
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

private func oldestReceiptFirst(
  _ lhs: MobileCommandReceipt,
  _ rhs: MobileCommandReceipt
) -> Bool {
  let lhsDate = lhs.completedAt ?? lhs.receivedAt
  let rhsDate = rhs.completedAt ?? rhs.receivedAt
  if lhsDate != rhsDate {
    return lhsDate < rhsDate
  }
  return lhs.status.rawValue < rhs.status.rawValue
}
