import CloudKit
import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto
import XCTest

final class MobileCloudMirrorCommandCancelTests: XCTestCase {
  func testCancelQueuedCommandWritesEncryptedReceiptAndSuppressesRelayExecution()
    async throws
  {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let database = InMemoryMobileCloudMirrorDatabase()
    let cipher = MobilePayloadCipher(rawKey: Data(repeating: 11, count: 32))
    let identity = MobileDeviceIdentity(id: "device-phone", displayName: "Phone")
    let client = MobileCloudMirrorSyncClient(
      database: database,
      cipher: cipher,
      deviceIdentity: identity,
      commandKeyID: "command-key"
    )
    let command = cancelMakeCommand(
      id: "command-cancel",
      risk: .high,
      targetRevision: 42,
      now: now
    )
    let queued = try await client.queueCommand(command, currentRevision: 42, now: now)

    let receipt = try await client.cancelCommand(
      queued.signedCommand.command,
      currentRevision: 42,
      now: now.addingTimeInterval(5)
    )
    let storedReceiptRecord = try await database.fetch(recordID: "receipt-\(command.id)")
    let openedReceipt: MobileCommandReceipt = try cipher.open(
      try XCTUnwrap(storedReceiptRecord?.envelope)
    )
    let pendingCommands = try await MobileCloudMirrorCommandQueue(
      database: database,
      cipher: cipher,
      trustStore: InMemoryMobileCommandTrustStore(devices: [
        MobileTrustedCommandDevice(
          id: identity.id,
          signingKeyFingerprint: try identity.signingKeyFingerprint(),
          signingPublicKeyRawRepresentation: try identity.signingPublicKeyRawRepresentation()
        )
      ])
    )
    .pendingCommands(stationID: command.stationID, now: now.addingTimeInterval(6))

    XCTAssertEqual(receipt.status, .cancelled)
    XCTAssertEqual(openedReceipt, receipt)
    XCTAssertEqual(storedReceiptRecord?.metadata.type, .receipt)
    XCTAssertEqual(pendingCommands, [])

    do {
      _ = try await client.cancelCommand(
        queued.signedCommand.command,
        currentRevision: 42,
        now: now.addingTimeInterval(7)
      )
      XCTFail("Expected existing receipt to remain immutable")
    } catch let error as MobileCloudMirrorSyncError {
      XCTAssertEqual(error, .commandAlreadyReceipted(command.id))
    }
  }

  func testCancelQueuedCommandAllowsSamePhysicalDeviceActor() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let database = InMemoryMobileCloudMirrorDatabase()
    let cipher = MobilePayloadCipher(rawKey: Data(repeating: 35, count: 32))
    let identity = MobileDeviceIdentity(id: "device-phone", displayName: "Phone")
    let client = MobileCloudMirrorSyncClient(
      database: database,
      cipher: cipher,
      deviceIdentity: identity,
      commandKeyID: "command-key"
    )
    var watchCommand = cancelMakeCommand(
      id: "command-watch-cancel",
      risk: .high,
      targetRevision: 42,
      now: now
    )
    watchCommand.status = .queued
    watchCommand.actorDeviceID = MobileCommandActorDeviceID.watchActorID(
      baseDeviceID: identity.id
    )

    let receipt = try await client.cancelCommand(
      watchCommand,
      currentRevision: 42,
      now: now.addingTimeInterval(5)
    )

    let receiptRecord = try await database.fetch(recordID: "receipt-\(watchCommand.id)")
    XCTAssertEqual(receipt.status, .cancelled)
    XCTAssertNotNil(receiptRecord)
  }

  func testCancelQueuedCommandRejectsClaimedCommandReceipts() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let database = InMemoryMobileCloudMirrorDatabase()
    let cipher = MobilePayloadCipher(rawKey: Data(repeating: 36, count: 32))
    let identity = MobileDeviceIdentity(id: "device-phone", displayName: "Phone")
    let client = MobileCloudMirrorSyncClient(
      database: database,
      cipher: cipher,
      deviceIdentity: identity,
      commandKeyID: "command-key"
    )
    let command = cancelMakeCommand(
      id: "command-claimed-cancel",
      risk: .high,
      targetRevision: 42,
      now: now
    )
    let queued = try await client.queueCommand(command, currentRevision: 42, now: now)
    let commandQueue = MobileCloudMirrorCommandQueue(
      database: database,
      cipher: cipher,
      trustStore: InMemoryMobileCommandTrustStore(devices: [
        MobileTrustedCommandDevice(
          id: identity.id,
          signingKeyFingerprint: try identity.signingKeyFingerprint(),
          signingPublicKeyRawRepresentation: try identity.signingPublicKeyRawRepresentation()
        )
      ])
    )
    _ = try await commandQueue.recordReceipt(
      MobileCommandReceipt(
        commandID: command.id,
        stationID: command.stationID,
        status: .accepted,
        message: "Command accepted by this Mac.",
        receivedAt: now.addingTimeInterval(1),
        executionRevision: 42
      ),
      keyID: "command-key",
      now: now.addingTimeInterval(1)
    )

    do {
      _ = try await client.cancelCommand(
        queued.signedCommand.command,
        currentRevision: 42,
        now: now.addingTimeInterval(2)
      )
      XCTFail("Expected claimed command cancellation rejection")
    } catch let error as MobileCloudMirrorSyncError {
      XCTAssertEqual(error, .commandAlreadyReceipted(command.id))
    }
  }

  func testCommandQueueRejectsReplayedCommandRecordWithDifferentRecordID() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let database = InMemoryMobileCloudMirrorDatabase()
    let cipher = MobilePayloadCipher(rawKey: Data(repeating: 33, count: 32))
    let identity = MobileDeviceIdentity(id: "device-phone", displayName: "Phone")
    let client = MobileCloudMirrorSyncClient(
      database: database,
      cipher: cipher,
      deviceIdentity: identity,
      commandKeyID: "command-key"
    )
    let command = cancelMakeCommand(
      id: "command-replay",
      risk: .high,
      targetRevision: 42,
      now: now
    )
    let queued = try await client.queueCommand(command, currentRevision: 42, now: now)
    let commandQueue = MobileCloudMirrorCommandQueue(
      database: database,
      cipher: cipher,
      trustStore: InMemoryMobileCommandTrustStore(devices: [
        MobileTrustedCommandDevice(
          id: identity.id,
          signingKeyFingerprint: try identity.signingKeyFingerprint(),
          signingPublicKeyRawRepresentation: try identity.signingPublicKeyRawRepresentation()
        )
      ])
    )
    let terminalReceipt = MobileCommandReceipt(
      commandID: command.id,
      stationID: command.stationID,
      status: .succeeded,
      message: "Already executed.",
      receivedAt: now.addingTimeInterval(1),
      completedAt: now.addingTimeInterval(2),
      executionRevision: 42
    )
    _ = try await commandQueue.recordReceipt(
      terminalReceipt,
      keyID: "command-key",
      now: now.addingTimeInterval(2)
    )
    let replayMetadata = MobileMirrorRecordMetadata(
      id: "command-replay-copy",
      type: .command,
      stationID: command.stationID,
      revision: 42,
      updatedAt: now.addingTimeInterval(3),
      expiresAt: now.addingTimeInterval(60)
    )
    let replayEnvelope = try cipher.seal(
      queued.signedCommand,
      keyID: "command-key",
      additionalAuthenticatedData: MobileCloudMirrorRecordAAD.data(for: replayMetadata),
      createdAt: now.addingTimeInterval(3)
    )
    try await database.save(
      MobileMirrorRecord(metadata: replayMetadata, envelope: replayEnvelope)
    )

    let pending = try await commandQueue.pendingCommands(
      stationID: command.stationID,
      now: now.addingTimeInterval(4)
    )

    XCTAssertEqual(pending, [])
  }

  func testCommandQueueDoesNotReturnCommandClaimedByNonTerminalReceipt() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let database = InMemoryMobileCloudMirrorDatabase()
    let cipher = MobilePayloadCipher(rawKey: Data(repeating: 34, count: 32))
    let identity = MobileDeviceIdentity(id: "device-phone", displayName: "Phone")
    let client = MobileCloudMirrorSyncClient(
      database: database,
      cipher: cipher,
      deviceIdentity: identity,
      commandKeyID: "command-key"
    )
    let command = cancelMakeCommand(
      id: "command-claimed",
      risk: .high,
      targetRevision: 42,
      now: now
    )
    _ = try await client.queueCommand(command, currentRevision: 42, now: now)
    let commandQueue = MobileCloudMirrorCommandQueue(
      database: database,
      cipher: cipher,
      trustStore: InMemoryMobileCommandTrustStore(devices: [
        MobileTrustedCommandDevice(
          id: identity.id,
          signingKeyFingerprint: try identity.signingKeyFingerprint(),
          signingPublicKeyRawRepresentation: try identity.signingPublicKeyRawRepresentation()
        )
      ])
    )
    _ = try await commandQueue.recordReceipt(
      MobileCommandReceipt(
        commandID: command.id,
        stationID: command.stationID,
        status: .accepted,
        message: "Command accepted by this Mac.",
        receivedAt: now.addingTimeInterval(1),
        executionRevision: 42
      ),
      keyID: "command-key",
      now: now.addingTimeInterval(1)
    )

    let pending = try await commandQueue.pendingCommands(
      stationID: command.stationID,
      now: now.addingTimeInterval(2)
    )

    XCTAssertEqual(pending, [])
  }

  func testCancelCommandRejectsOtherDeviceAndNonQueuedCommands() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let database = InMemoryMobileCloudMirrorDatabase()
    let client = MobileCloudMirrorSyncClient(
      database: database,
      cipher: MobilePayloadCipher(rawKey: Data(repeating: 12, count: 32)),
      deviceIdentity: MobileDeviceIdentity(id: "device-phone", displayName: "Phone"),
      commandKeyID: "command-key"
    )
    var otherDeviceCommand = cancelMakeCommand(
      id: "command-other-device",
      risk: .high,
      targetRevision: 42,
      now: now
    )
    otherDeviceCommand.status = .queued
    otherDeviceCommand.actorDeviceID = "device-watch"
    var runningCommand = cancelMakeCommand(
      id: "command-running",
      risk: .high,
      targetRevision: 42,
      now: now
    )
    runningCommand.status = .running
    runningCommand.actorDeviceID = "device-phone"

    do {
      _ = try await client.cancelCommand(
        otherDeviceCommand,
        currentRevision: 42,
        now: now
      )
      XCTFail("Expected other-device cancellation rejection")
    } catch let error as MobileCloudMirrorSyncError {
      XCTAssertEqual(
        error,
        .cannotCancelOtherDeviceCommand(commandID: otherDeviceCommand.id)
      )
    }

    do {
      _ = try await client.cancelCommand(runningCommand, currentRevision: 42, now: now)
      XCTFail("Expected running-command cancellation rejection")
    } catch let error as MobileCloudMirrorSyncError {
      XCTAssertEqual(
        error,
        .cannotCancelCommandStatus(commandID: runningCommand.id, status: .running)
      )
    }

    let records = try await database.fetchAll(stationID: otherDeviceCommand.stationID)
    XCTAssertEqual(records, [])
  }

  func testQueueCommandRejectsDestructiveCommandWithoutAuditReason() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let database = InMemoryMobileCloudMirrorDatabase()
    let cipher = MobilePayloadCipher(rawKey: Data(repeating: 10, count: 32))
    let client = MobileCloudMirrorSyncClient(
      database: database,
      cipher: cipher,
      deviceIdentity: MobileDeviceIdentity(id: "device-phone", displayName: "Phone"),
      commandKeyID: "command-key"
    )
    let command = cancelMakeCommand(
      id: "command-merge",
      risk: .destructive,
      targetRevision: 42,
      auditReason: nil,
      now: now
    )

    do {
      _ = try await client.queueCommand(command, currentRevision: 42, now: now)
      XCTFail("Expected missing audit reason rejection")
    } catch let error as MobileCommandValidationError {
      XCTAssertEqual(error, .destructiveCommandMissingAuditReason)
    }

    let records = try await database.fetchAll(stationID: command.stationID)
    XCTAssertEqual(records, [])
  }

  private func cancelMakeCommand(
    id: String,
    risk: MobileCommandRisk,
    targetRevision: Int64,
    auditReason: String? = "Reviewed on iPhone",
    now: Date
  ) -> MobileCommandRecord {
    MobileCommandRecord(
      id: id,
      stationID: "station-mac-studio",
      kind: risk == .destructive ? .pullRequestMerge : .pullRequestApprove,
      risk: risk,
      status: .draft,
      title: risk == .destructive ? "Merge PR" : "Approve PR",
      confirmationText: "Apply command to PR #812.",
      auditReason: auditReason,
      target: MobileCommandTarget(
        stationID: "station-mac-studio",
        reviewID: "review-812",
        targetRevision: targetRevision
      ),
      actorDeviceID: "",
      createdAt: now,
      expiresAt: now.addingTimeInterval(60),
      updatedAt: now
    )
  }
}
