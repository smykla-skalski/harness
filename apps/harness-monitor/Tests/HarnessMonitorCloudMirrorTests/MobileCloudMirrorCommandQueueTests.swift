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
