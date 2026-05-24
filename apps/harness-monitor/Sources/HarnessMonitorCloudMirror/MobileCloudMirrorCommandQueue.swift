import Foundation
import HarnessMonitorCore
import HarnessMonitorCrypto

public enum MobileCloudMirrorCommandQueueError: Error, Equatable, Sendable {
  case missingCommandEnvelope(String)
  case untrustedDevice(commandID: String, actorDeviceID: String, signingKeyFingerprint: String)
  case invalidSignature(String)
  case stationMismatch(commandID: String, expected: String, actual: String)
}

public struct MobileTrustedCommandDevice: Equatable, Identifiable, Sendable {
  public var id: String
  public var signingKeyFingerprint: String
  public var signingPublicKeyRawRepresentation: Data

  public init(
    id: String,
    signingKeyFingerprint: String,
    signingPublicKeyRawRepresentation: Data
  ) {
    self.id = id
    self.signingKeyFingerprint = signingKeyFingerprint
    self.signingPublicKeyRawRepresentation = signingPublicKeyRawRepresentation
  }
}

public protocol MobileCommandTrustStore: Sendable {
  func publicSigningKey(
    actorDeviceID: String,
    signingKeyFingerprint: String
  ) async throws -> Data?
}

public actor InMemoryMobileCommandTrustStore: MobileCommandTrustStore {
  private var devicesByKey: [String: MobileTrustedCommandDevice]

  public init(devices: [MobileTrustedCommandDevice] = []) {
    devicesByKey = Dictionary(uniqueKeysWithValues: devices.map { (Self.key(for: $0), $0) })
  }

  public func trust(_ device: MobileTrustedCommandDevice) {
    devicesByKey[Self.key(for: device)] = device
  }

  public func publicSigningKey(
    actorDeviceID: String,
    signingKeyFingerprint: String
  ) async throws -> Data? {
    devicesByKey[Self.key(actorDeviceID: actorDeviceID, fingerprint: signingKeyFingerprint)]?
      .signingPublicKeyRawRepresentation
  }

  private nonisolated static func key(for device: MobileTrustedCommandDevice) -> String {
    key(actorDeviceID: device.id, fingerprint: device.signingKeyFingerprint)
  }

  private nonisolated static func key(actorDeviceID: String, fingerprint: String) -> String {
    "\(actorDeviceID)|\(fingerprint)"
  }
}

public actor MobileCloudMirrorCommandQueue {
  private let database: any MobileCloudMirrorDatabase
  private let cipher: MobilePayloadCipher
  private let trustStore: any MobileCommandTrustStore
  private let retention: TimeInterval

  public init(
    database: any MobileCloudMirrorDatabase,
    cipher: MobilePayloadCipher,
    trustStore: any MobileCommandTrustStore,
    retention: TimeInterval = MobileCloudMirrorSchema.sevenDayRetention
  ) {
    self.database = database
    self.cipher = cipher
    self.trustStore = trustStore
    self.retention = retention
  }

  public func pendingCommands(
    stationID: String,
    now: Date = .now
  ) async throws -> [MobileCommandRecord] {
    try await pendingSignedCommands(stationID: stationID, now: now).map(\.command)
  }

  public func pendingSignedCommands(
    stationID: String,
    now: Date = .now
  ) async throws -> [MobileSignedCommand] {
    let records = try await database.fetchAll(stationID: stationID)
    var commands: [MobileSignedCommand] = []
    for record in records where isPendingCommandRecord(record, now: now) {
      guard let envelope = record.envelope else {
        throw MobileCloudMirrorCommandQueueError.missingCommandEnvelope(record.id)
      }
      let signedCommand: MobileSignedCommand = try cipher.open(envelope)
      try await validate(signedCommand, stationID: stationID)
      guard signedCommand.command.status != .draft,
        !signedCommand.command.status.isTerminal,
        !signedCommand.command.isExpired(now: now)
      else {
        continue
      }
      commands.append(signedCommand)
    }
    return commands.sorted { $0.command.createdAt < $1.command.createdAt }
  }

  public func recordReceipt(
    _ receipt: MobileCommandReceipt,
    keyID: String,
    now: Date = .now
  ) async throws -> MobileMirrorRecord {
    let metadata = MobileMirrorRecordMetadata(
      id: "receipt-\(receipt.commandID)",
      type: .receipt,
      stationID: receipt.stationID,
      revision: receipt.executionRevision,
      updatedAt: receipt.completedAt ?? receipt.receivedAt,
      expiresAt: now.addingTimeInterval(retention)
    )
    let envelope = try cipher.seal(
      receipt,
      keyID: keyID,
      additionalAuthenticatedData: MobileCloudMirrorRecordAAD.data(for: metadata),
      createdAt: now
    )
    let record = MobileMirrorRecord(metadata: metadata, envelope: envelope)
    try await database.save(record)
    return record
  }

  private func validate(
    _ signedCommand: MobileSignedCommand,
    stationID: String
  ) async throws {
    guard signedCommand.command.stationID == stationID else {
      throw MobileCloudMirrorCommandQueueError.stationMismatch(
        commandID: signedCommand.command.id,
        expected: stationID,
        actual: signedCommand.command.stationID
      )
    }
    guard
      let publicKey = try await trustStore.publicSigningKey(
        actorDeviceID: signedCommand.command.actorDeviceID,
        signingKeyFingerprint: signedCommand.signingKeyFingerprint
      )
    else {
      throw MobileCloudMirrorCommandQueueError.untrustedDevice(
        commandID: signedCommand.command.id,
        actorDeviceID: signedCommand.command.actorDeviceID,
        signingKeyFingerprint: signedCommand.signingKeyFingerprint
      )
    }
    guard
      try MobileCommandSigner.verify(
        signedCommand,
        publicKeyRawRepresentation: publicKey
      )
    else {
      throw MobileCloudMirrorCommandQueueError.invalidSignature(signedCommand.command.id)
    }
  }

  private nonisolated func isPendingCommandRecord(
    _ record: MobileMirrorRecord,
    now: Date
  ) -> Bool {
    record.metadata.type == .command
      && !record.metadata.tombstone
      && record.metadata.expiresAt > now
  }
}
