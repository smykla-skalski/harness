import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto
import XCTest

final class MobileCloudMirrorCommandQueueTests: XCTestCase {
  func testPendingCommandsRequireTrustedDeviceSignature() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let database = InMemoryMobileCloudMirrorDatabase()
    let cipher = MobilePayloadCipher(rawKey: Data(repeating: 11, count: 32))
    let identity = MobileDeviceIdentity(id: "device-phone", displayName: "Phone")
    let trustedStore = InMemoryMobileCommandTrustStore(devices: [
      try trustedDevice(for: identity)
    ])
    let syncClient = MobileCloudMirrorSyncClient(
      database: database,
      cipher: cipher,
      deviceIdentity: identity,
      commandKeyID: "command-key"
    )
    let command = makeCommand(id: "command-approve", targetRevision: 42, now: now)
    let queued = try await syncClient.queueCommand(command, currentRevision: 42, now: now)
    let commandQueue = MobileCloudMirrorCommandQueue(
      database: database,
      cipher: cipher,
      trustStore: trustedStore
    )

    let pending = try await commandQueue.pendingSignedCommands(
      stationID: command.stationID,
      now: now
    )

    XCTAssertEqual(pending, [queued.signedCommand])
  }

  func testPendingCommandsOpenEveryTrustedDeviceCipherAndWriteMatchingReceipt() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let database = InMemoryMobileCloudMirrorDatabase()
    let phoneKey = Data(repeating: 21, count: 32)
    let watchKey = Data(repeating: 22, count: 32)
    let phoneIdentity = MobileDeviceIdentity(id: "device-phone", displayName: "Phone")
    let watchIdentity = MobileDeviceIdentity(id: "device-watch", displayName: "Watch")
    let trustedStore = PairingCommandTrustStore(devices: [
      try pairedDevice(for: phoneIdentity, symmetricKey: phoneKey),
      try pairedDevice(for: watchIdentity, symmetricKey: watchKey),
    ])
    let phoneClient = MobileCloudMirrorSyncClient(
      database: database,
      cipher: MobilePayloadCipher(rawKey: phoneKey),
      deviceIdentity: phoneIdentity,
      commandKeyID: "command-key"
    )
    let watchClient = MobileCloudMirrorSyncClient(
      database: database,
      cipher: MobilePayloadCipher(rawKey: watchKey),
      deviceIdentity: watchIdentity,
      commandKeyID: "command-key"
    )
    let phoneCommand = makeCommand(id: "command-phone", targetRevision: 42, now: now)
    let watchCommand = makeCommand(
      id: "command-watch",
      targetRevision: 42,
      now: now.addingTimeInterval(1)
    )
    let queuedPhone = try await phoneClient.queueCommand(
      phoneCommand,
      currentRevision: 42,
      now: now
    )
    let queuedWatch = try await watchClient.queueCommand(
      watchCommand,
      currentRevision: 42,
      now: now.addingTimeInterval(1)
    )
    let commandQueue = MobileCloudMirrorCommandQueue(
      database: database,
      trustedDeviceStore: trustedStore
    )

    let pending = try await commandQueue.pendingSignedCommands(
      stationID: phoneCommand.stationID,
      now: now
    )
    let receipt = MobileCommandReceipt(
      commandID: phoneCommand.id,
      stationID: phoneCommand.stationID,
      status: .succeeded,
      message: "Approved.",
      receivedAt: now,
      completedAt: now,
      executionRevision: 42
    )
    _ = try await commandQueue.recordReceipt(
      receipt,
      forCommandID: phoneCommand.id,
      fallbackKeyID: "fallback",
      now: now
    )
    let receiptRecord = try await database.fetch(recordID: "receipt-\(phoneCommand.id)")
    let openedReceipt: MobileCommandReceipt = try MobilePayloadCipher(rawKey: phoneKey)
      .open(try XCTUnwrap(receiptRecord?.envelope))

    XCTAssertEqual(
      pending.map(\.command.id),
      [queuedPhone.signedCommand.command.id, queuedWatch.signedCommand.command.id]
    )
    XCTAssertEqual(openedReceipt, receipt)
    XCTAssertEqual(receiptRecord?.envelope?.keyID, "command-key")
  }

  func testPendingCommandsRejectUntrustedDevices() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let database = InMemoryMobileCloudMirrorDatabase()
    let cipher = MobilePayloadCipher(rawKey: Data(repeating: 12, count: 32))
    let identity = MobileDeviceIdentity(id: "device-phone", displayName: "Phone")
    let syncClient = MobileCloudMirrorSyncClient(
      database: database,
      cipher: cipher,
      deviceIdentity: identity,
      commandKeyID: "command-key"
    )
    let command = makeCommand(id: "command-untrusted", targetRevision: 42, now: now)
    let queued = try await syncClient.queueCommand(command, currentRevision: 42, now: now)
    let commandQueue = MobileCloudMirrorCommandQueue(
      database: database,
      cipher: cipher,
      trustStore: InMemoryMobileCommandTrustStore()
    )

    do {
      _ = try await commandQueue.pendingCommands(stationID: command.stationID, now: now)
      XCTFail("Expected untrusted device rejection")
    } catch let error as MobileCloudMirrorCommandQueueError {
      XCTAssertEqual(
        error,
        .untrustedDevice(
          commandID: command.id,
          actorDeviceID: identity.id,
          signingKeyFingerprint: queued.signedCommand.signingKeyFingerprint
        )
      )
    }
  }

  func testPendingCommandsRejectInvalidSignatures() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let database = InMemoryMobileCloudMirrorDatabase()
    let cipher = MobilePayloadCipher(rawKey: Data(repeating: 13, count: 32))
    let identity = MobileDeviceIdentity(id: "device-phone", displayName: "Phone")
    let trustedStore = InMemoryMobileCommandTrustStore(devices: [
      try trustedDevice(for: identity)
    ])
    let command = makeCommand(id: "command-tampered", targetRevision: 42, now: now)
    var signed = try MobileCommandSigner.sign(command: command, identity: identity, signedAt: now)
    signed.command.title = "Tampered command"
    let metadata = MobileMirrorRecordMetadata(
      id: command.id,
      type: .command,
      stationID: command.stationID,
      revision: 42,
      updatedAt: now,
      expiresAt: command.expiresAt
    )
    let envelope = try cipher.seal(
      signed,
      keyID: "command-key",
      additionalAuthenticatedData: MobileCloudMirrorRecordAAD.data(for: metadata),
      createdAt: now
    )
    try await database.save(MobileMirrorRecord(metadata: metadata, envelope: envelope))
    let commandQueue = MobileCloudMirrorCommandQueue(
      database: database,
      cipher: cipher,
      trustStore: trustedStore
    )

    do {
      _ = try await commandQueue.pendingCommands(stationID: command.stationID, now: now)
      XCTFail("Expected invalid signature rejection")
    } catch let error as MobileCloudMirrorCommandQueueError {
      XCTAssertEqual(error, .invalidSignature(command.id))
    }
  }

  func testRecordReceiptWritesEncryptedReceiptRecord() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let database = InMemoryMobileCloudMirrorDatabase()
    let cipher = MobilePayloadCipher(rawKey: Data(repeating: 14, count: 32))
    let commandQueue = MobileCloudMirrorCommandQueue(
      database: database,
      cipher: cipher,
      trustStore: InMemoryMobileCommandTrustStore()
    )
    let receipt = MobileCommandReceipt(
      commandID: "command-approve",
      stationID: "station-mac-studio",
      status: .succeeded,
      message: "Approved.",
      receivedAt: now,
      completedAt: now,
      executionRevision: 42
    )

    let record = try await commandQueue.recordReceipt(
      receipt,
      keyID: "receipt-key",
      now: now
    )
    let stored = try await database.fetch(recordID: "receipt-command-approve")
    let opened: MobileCommandReceipt = try cipher.open(try XCTUnwrap(stored?.envelope))

    XCTAssertEqual(stored, record)
    XCTAssertEqual(record.metadata.type, .receipt)
    XCTAssertEqual(opened, receipt)
  }

  private func trustedDevice(
    for identity: MobileDeviceIdentity
  ) throws -> MobileTrustedCommandDevice {
    MobileTrustedCommandDevice(
      id: identity.id,
      signingKeyFingerprint: try identity.signingKeyFingerprint(),
      signingPublicKeyRawRepresentation: try identity.signingPublicKeyRawRepresentation()
    )
  }

  private func pairedDevice(
    for identity: MobileDeviceIdentity,
    symmetricKey: Data
  ) throws -> MobilePairingTrustedDevice {
    MobilePairingTrustedDevice(
      stationID: "station-mac-studio",
      deviceID: identity.id,
      displayName: identity.displayName,
      signingKeyFingerprint: try identity.signingKeyFingerprint(),
      signingPublicKeyRawRepresentation: try identity.signingPublicKeyRawRepresentation(),
      agreementPublicKeyRawRepresentation: try identity.agreementPublicKeyRawRepresentation(),
      snapshotKeyID: "snapshot-key",
      commandKeyID: "command-key",
      symmetricKeyRawRepresentation: symmetricKey,
      pairedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
  }

  private func makeCommand(
    id: String,
    targetRevision: Int64,
    now: Date
  ) -> MobileCommandRecord {
    MobileCommandRecord(
      id: id,
      stationID: "station-mac-studio",
      kind: .pullRequestApprove,
      risk: .high,
      status: .queued,
      title: "Approve PR",
      confirmationText: "Approve PR #812.",
      target: MobileCommandTarget(
        stationID: "station-mac-studio",
        reviewID: "review-812",
        targetRevision: targetRevision
      ),
      actorDeviceID: "device-phone",
      createdAt: now,
      expiresAt: now.addingTimeInterval(60),
      updatedAt: now
    )
  }
}

private actor PairingCommandTrustStore: MobilePairingTrustedDeviceStore, MobileCommandTrustStore {
  private var devicesByKey: [String: MobilePairingTrustedDevice]

  init(devices: [MobilePairingTrustedDevice]) {
    devicesByKey = Dictionary(uniqueKeysWithValues: devices.map { (Self.key(for: $0), $0) })
  }

  func trust(_ device: MobilePairingTrustedDevice) async throws {
    devicesByKey[Self.key(for: device)] = device
  }

  func trustedDevice(
    deviceID: String,
    signingKeyFingerprint: String
  ) async throws -> MobilePairingTrustedDevice? {
    devicesByKey[Self.key(deviceID: deviceID, fingerprint: signingKeyFingerprint)]
  }

  func trustedDevices() async throws -> [MobilePairingTrustedDevice] {
    devicesByKey.values.sorted { $0.deviceID < $1.deviceID }
  }

  func publicSigningKey(
    actorDeviceID: String,
    signingKeyFingerprint: String
  ) async throws -> Data? {
    devicesByKey[Self.key(deviceID: actorDeviceID, fingerprint: signingKeyFingerprint)]?
      .signingPublicKeyRawRepresentation
  }

  private nonisolated static func key(for device: MobilePairingTrustedDevice) -> String {
    key(deviceID: device.deviceID, fingerprint: device.signingKeyFingerprint)
  }

  private nonisolated static func key(deviceID: String, fingerprint: String) -> String {
    "\(deviceID)|\(fingerprint)"
  }
}
