import Foundation
import HarnessMonitorCore
import HarnessMonitorCrypto

public enum MobileCloudMirrorCommandQueueError: Error, Equatable, Sendable {
  case emptyReceiptCommandID
  case emptyReceiptStationID
  case emptyReceiptMessage
  case missingCommandEnvelope(String)
  case missingReceiptCipher(String)
  case receiptCommandMismatch(expected: String, actual: String)
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

  nonisolated private static func key(for device: MobileTrustedCommandDevice) -> String {
    key(actorDeviceID: device.id, fingerprint: device.signingKeyFingerprint)
  }

  nonisolated private static func key(actorDeviceID: String, fingerprint: String) -> String {
    "\(actorDeviceID)|\(fingerprint)"
  }
}

public actor MobileCloudMirrorCommandQueue {
  private let database: any MobileCloudMirrorDatabase
  private let cipher: MobilePayloadCipher?
  private let trustStore: any MobileCommandTrustStore
  private let pairingTrustStore: (any MobilePairingTrustedDeviceStore)?
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
    pairingTrustStore = nil
    self.retention = retention
  }

  public init(
    database: any MobileCloudMirrorDatabase,
    trustedDeviceStore: any MobilePairingTrustedDeviceStore & MobileCommandTrustStore,
    retention: TimeInterval = MobileCloudMirrorSchema.sevenDayRetention
  ) {
    self.database = database
    cipher = nil
    trustStore = trustedDeviceStore
    pairingTrustStore = trustedDeviceStore
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
    let receiptedCommandIDs = try await receiptedCommandIDs(
      in: records,
      stationID: stationID,
      now: now
    )
    var commands: [MobileSignedCommand] = []
    for record in records
    where isPendingCommandRecord(record, now: now) {
      guard record.envelope != nil else {
        throw MobileCloudMirrorCommandQueueError.missingCommandEnvelope(record.id)
      }
      let openedCommand: MobileSignedCommand?
      do {
        openedCommand = try await openSignedCommand(record, stationID: stationID)?.command
      } catch {
        continue
      }
      guard let signedCommand = openedCommand else {
        continue
      }
      try await validate(signedCommand, stationID: stationID)
      guard signedCommand.command.id == record.id,
        !receiptedCommandIDs.contains(signedCommand.command.id)
      else {
        continue
      }
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
    try validateReceipt(receipt)
    guard let cipher else {
      throw MobileCloudMirrorCommandQueueError.missingReceiptCipher(receipt.commandID)
    }
    return try await recordReceipt(receipt, keyID: keyID, cipher: cipher, now: now)
  }

  public func recordReceipt(
    _ receipt: MobileCommandReceipt,
    forCommandID commandID: String,
    fallbackKeyID: String,
    now: Date = .now
  ) async throws -> MobileMirrorRecord {
    try validateReceipt(receipt, expectedCommandID: commandID)
    guard let record = try await database.fetch(recordID: commandID),
      let opened = try await openSignedCommand(record, stationID: receipt.stationID)
    else {
      return try await recordReceipt(receipt, keyID: fallbackKeyID, now: now)
    }
    try await validate(opened.command, stationID: receipt.stationID)
    guard let device = opened.device else {
      return try await recordReceipt(receipt, keyID: fallbackKeyID, now: now)
    }
    return try await recordReceipt(
      receipt,
      keyID: device.commandKeyID,
      cipher: MobilePayloadCipher(rawKey: device.symmetricKeyRawRepresentation),
      now: now
    )
  }

  private func recordReceipt(
    _ receipt: MobileCommandReceipt,
    keyID: String,
    cipher: MobilePayloadCipher,
    now: Date
  ) async throws -> MobileMirrorRecord {
    let metadata = MobileMirrorRecordMetadata(
      id: receiptRecordID(for: receipt),
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

  private func validateReceipt(
    _ receipt: MobileCommandReceipt,
    expectedCommandID: String? = nil
  ) throws {
    let receiptCommandID = receipt.commandID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !receiptCommandID.isEmpty else {
      throw MobileCloudMirrorCommandQueueError.emptyReceiptCommandID
    }
    let receiptStationID = receipt.stationID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !receiptStationID.isEmpty else {
      throw MobileCloudMirrorCommandQueueError.emptyReceiptStationID
    }
    let receiptMessage = receipt.message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !receiptMessage.isEmpty else {
      throw MobileCloudMirrorCommandQueueError.emptyReceiptMessage
    }
    guard let expectedCommandID else {
      return
    }
    let expected = expectedCommandID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard receiptCommandID == expected else {
      throw MobileCloudMirrorCommandQueueError.receiptCommandMismatch(
        expected: expected,
        actual: receiptCommandID
      )
    }
  }

  private func openSignedCommand(
    _ record: MobileMirrorRecord,
    stationID: String
  ) async throws -> (command: MobileSignedCommand, device: MobilePairingTrustedDevice?)? {
    guard let envelope = record.envelope,
      envelope.additionalAuthenticatedData == MobileCloudMirrorRecordAAD.data(for: record.metadata)
    else {
      return nil
    }
    return try await openSignedCommand(envelope, stationID: stationID)
  }

  private func openSignedCommand(
    _ envelope: MobileEncryptedEnvelope,
    stationID: String
  ) async throws -> (command: MobileSignedCommand, device: MobilePairingTrustedDevice?)? {
    if let cipher {
      let command: MobileSignedCommand = try cipher.open(envelope)
      return (command, nil)
    }
    guard let pairingTrustStore else {
      return nil
    }
    let devices = try await pairingTrustStore.trustedDevices()
      .filter { $0.stationID == stationID }
    for device in devices {
      let deviceCipher = MobilePayloadCipher(rawKey: device.symmetricKeyRawRepresentation)
      guard let command: MobileSignedCommand = try? deviceCipher.open(envelope),
        MobileCommandActorDeviceID.isTrustedActor(
          command.command.actorDeviceID,
          for: device.deviceID
        ),
        command.signingKeyFingerprint == device.signingKeyFingerprint
      else {
        continue
      }
      return (command, device)
    }
    return nil
  }

  private func openReceipt(
    _ record: MobileMirrorRecord,
    stationID: String
  ) async throws -> MobileCommandReceipt? {
    guard let envelope = record.envelope,
      envelope.additionalAuthenticatedData == MobileCloudMirrorRecordAAD.data(for: record.metadata)
    else {
      return nil
    }
    if let cipher {
      return try cipher.open(envelope)
    }
    guard let pairingTrustStore else {
      return nil
    }
    let devices = try await pairingTrustStore.trustedDevices()
      .filter { $0.stationID == stationID }
    for device in devices {
      let deviceCipher = MobilePayloadCipher(rawKey: device.symmetricKeyRawRepresentation)
      if let receipt: MobileCommandReceipt = try? deviceCipher.open(envelope) {
        return receipt
      }
    }
    return nil
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
      let publicKey = try await publicSigningKey(for: signedCommand)
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

  private func publicSigningKey(for signedCommand: MobileSignedCommand) async throws -> Data? {
    if let exactPublicKey = try await trustStore.publicSigningKey(
      actorDeviceID: signedCommand.command.actorDeviceID,
      signingKeyFingerprint: signedCommand.signingKeyFingerprint
    ) {
      return exactPublicKey
    }
    let baseDeviceID = MobileCommandActorDeviceID.trustedBaseDeviceID(
      for: signedCommand.command.actorDeviceID
    )
    guard baseDeviceID != signedCommand.command.actorDeviceID else {
      return nil
    }
    return try await trustStore.publicSigningKey(
      actorDeviceID: baseDeviceID,
      signingKeyFingerprint: signedCommand.signingKeyFingerprint
    )
  }

  nonisolated private func isPendingCommandRecord(
    _ record: MobileMirrorRecord,
    now: Date
  ) -> Bool {
    record.metadata.type == .command
      && !record.metadata.tombstone
      && record.metadata.expiresAt > now
  }

  private func receiptedCommandIDs(
    in records: [MobileMirrorRecord],
    stationID: String,
    now: Date
  ) async throws -> Set<String> {
    var commandIDs = Set<String>()
    for record in records {
      guard record.metadata.type == .receipt,
        !record.metadata.tombstone,
        record.metadata.expiresAt > now,
        record.id.hasPrefix("receipt-")
      else {
        continue
      }
      let openedReceipt: MobileCommandReceipt?
      do {
        openedReceipt = try await openReceipt(record, stationID: stationID)
      } catch {
        continue
      }
      if let receipt = openedReceipt {
        if receipt.stationID == stationID {
          commandIDs.insert(receipt.commandID)
        }
      }
    }
    return commandIDs
  }

  nonisolated private func receiptRecordID(for receipt: MobileCommandReceipt) -> String {
    if receipt.status.isTerminal {
      return "receipt-\(receipt.commandID)"
    }
    return "receipt-\(receipt.commandID)-\(receipt.status.rawValue)"
  }

}
