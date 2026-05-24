import Foundation
import HarnessMonitorCore
import HarnessMonitorCrypto

public enum MobileCloudMirrorSyncError: Error, Equatable, Sendable {
  case missingSnapshotEnvelope(String)
  case staleSnapshot(Date)
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

  public init(
    database: any MobileCloudMirrorDatabase,
    cipher: MobilePayloadCipher,
    deviceIdentity: MobileDeviceIdentity,
    commandKeyID: String
  ) {
    self.database = database
    self.cipher = cipher
    self.deviceIdentity = deviceIdentity
    self.commandKeyID = commandKeyID
  }

  public func fetchLatestSnapshot(
    stationID: String,
    now: Date = .now
  ) async throws -> MobileMirrorSnapshot? {
    let records = try await database.fetchAll(stationID: stationID)
    guard
      let record =
        records
        .filter({ $0.metadata.type == .snapshot && !$0.metadata.tombstone })
        .sorted(by: isNewer)
        .first
    else {
      return nil
    }
    guard record.metadata.expiresAt > now else {
      throw MobileCloudMirrorSyncError.staleSnapshot(record.metadata.expiresAt)
    }
    guard let envelope = record.envelope else {
      throw MobileCloudMirrorSyncError.missingSnapshotEnvelope(record.id)
    }
    let snapshot: MobileMirrorSnapshot = try cipher.open(envelope)
    guard snapshot.expiresAt > now else {
      throw MobileCloudMirrorSyncError.staleSnapshot(snapshot.expiresAt)
    }
    return snapshot
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
      expiresAt: validatedCommand.expiresAt
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

  private nonisolated func isNewer(
    _ lhs: MobileMirrorRecord,
    _ rhs: MobileMirrorRecord
  ) -> Bool {
    if lhs.metadata.revision != rhs.metadata.revision {
      return lhs.metadata.revision > rhs.metadata.revision
    }
    return lhs.metadata.updatedAt > rhs.metadata.updatedAt
  }
}
