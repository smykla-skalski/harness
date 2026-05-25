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
