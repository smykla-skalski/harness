import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto
import HarnessMonitorMacRelay
import XCTest

final class MobileMacRelayServiceTests: XCTestCase {
  func testRelayExecutesQueuedCommandOnce() async throws {
    let snapshot = MobileDemoFixtures.snapshot()
    var command = snapshot.commands.first { $0.status == .queued }!
    command.target.targetRevision = snapshot.revision
    let queue = InMemoryMobileRelayCommandQueue(commands: [command])
    let relay = MobileMacRelayService(
      stationID: command.stationID,
      snapshotSource: FixedSnapshotSource(snapshot: snapshot),
      commandQueue: queue,
      executor: EchoMobileRelayCommandExecutor()
    )

    let firstReceipts = try await relay.executePendingCommands()
    let secondReceipts = try await relay.executePendingCommands()

    XCTAssertEqual(firstReceipts.count, 1)
    XCTAssertEqual(firstReceipts.first?.status, .succeeded)
    XCTAssertEqual(secondReceipts, [])
  }

  func testRelayRejectsStaleHighRiskCommand() async throws {
    let snapshot = MobileDemoFixtures.snapshot()
    var command = snapshot.commands.first { $0.status == .queued }!
    command.target.targetRevision = snapshot.revision - 1
    let queue = InMemoryMobileRelayCommandQueue(commands: [command])
    let relay = MobileMacRelayService(
      stationID: command.stationID,
      snapshotSource: FixedSnapshotSource(snapshot: snapshot),
      commandQueue: queue,
      executor: EchoMobileRelayCommandExecutor()
    )

    let receipts = try await relay.executePendingCommands()

    XCTAssertEqual(receipts.first?.status, .failed)
    XCTAssertTrue(receipts.first?.message.contains("Fresh-state validation") == true)
  }

  func testRelayConsumesCloudMirrorQueueAndWritesEncryptedReceipt() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = MobileDemoFixtures.snapshot(now: now)
    let stationID = "station-mac-studio"
    let database = InMemoryMobileCloudMirrorDatabase()
    let cipher = MobilePayloadCipher(rawKey: Data(repeating: 15, count: 32))
    let identity = MobileDeviceIdentity(id: "device-phone", displayName: "Phone")
    let trustStore = InMemoryMobileCommandTrustStore(devices: [
      try trustedDevice(for: identity)
    ])
    let syncClient = MobileCloudMirrorSyncClient(
      database: database,
      cipher: cipher,
      deviceIdentity: identity,
      commandKeyID: "command-key"
    )
    let command = MobileCommandRecord(
      id: "command-approve-live",
      stationID: stationID,
      kind: .pullRequestApprove,
      risk: .high,
      status: .draft,
      title: "Approve PR",
      confirmationText: "Approve PR #812.",
      target: MobileCommandTarget(
        stationID: stationID,
        reviewID: "review-812",
        targetRevision: snapshot.revision
      ),
      actorDeviceID: "",
      createdAt: now,
      expiresAt: now.addingTimeInterval(60),
      updatedAt: now
    )
    _ = try await syncClient.queueCommand(
      command,
      currentRevision: snapshot.revision,
      now: now
    )
    let relayQueue = MobileCloudMirrorRelayCommandQueue(
      commandQueue: MobileCloudMirrorCommandQueue(
        database: database,
        cipher: cipher,
        trustStore: trustStore
      ),
      receiptKeyID: "receipt-key",
      now: { now }
    )
    let relay = MobileMacRelayService(
      stationID: stationID,
      snapshotSource: FixedSnapshotSource(snapshot: snapshot),
      commandQueue: relayQueue,
      executor: EchoMobileRelayCommandExecutor()
    )

    let receipts = try await relay.executePendingCommands(now: now)
    let receiptRecord = try await database.fetch(recordID: "receipt-\(command.id)")
    let storedReceipt: MobileCommandReceipt = try cipher.open(
      try XCTUnwrap(receiptRecord?.envelope)
    )

    XCTAssertEqual(receipts.count, 1)
    XCTAssertEqual(receipts.first?.status, .succeeded)
    XCTAssertEqual(storedReceipt.commandID, command.id)
    XCTAssertEqual(receiptRecord?.metadata.type, .receipt)
  }

  func testMacPairingHTTPServerAcceptsPhonePairingAndTrustsDevice() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let stationIdentity = MobilePairingStationIdentity(
      stationID: "station-mac-studio",
      stationName: "Studio",
      snapshotKeyID: "snapshot-key",
      commandKeyID: "command-key",
      createdAt: now
    )
    let trustStore = try MobileMacTrustedCommandDeviceStore()
    let server = MobilePairingHTTPServer(
      stationIdentity: stationIdentity,
      trustStore: trustStore,
      now: { now }
    )
    let invitation = try await server.start(invitationTTL: 60)
    defer { server.stop() }
    let invitationURL = try MobilePairingInvitationCodec.encode(invitation)
    let deviceIdentity = MobileDeviceIdentity(
      id: "device-phone",
      displayName: "Bart's iPhone",
      createdAt: now
    )
    let service = MobilePairingService(transport: URLSessionMobilePairingTransport())

    let credential = try await service.pair(
      invitation: invitation,
      deviceIdentity: deviceIdentity,
      now: now
    )
    let trustedDevice = try await trustStore.trustedDevice(
      deviceID: deviceIdentity.id,
      signingKeyFingerprint: try deviceIdentity.signingKeyFingerprint()
    )
    let publicSigningKey = try await trustStore.publicSigningKey(
      actorDeviceID: deviceIdentity.id,
      signingKeyFingerprint: try deviceIdentity.signingKeyFingerprint()
    )

    XCTAssertEqual(invitationURL.scheme, "harness")
    XCTAssertEqual(invitationURL.host, "pair")
    XCTAssertEqual(credential.stationID, stationIdentity.stationID)
    XCTAssertEqual(
      credential.symmetricKeyRawRepresentation, trustedDevice?.symmetricKeyRawRepresentation)
    XCTAssertEqual(publicSigningKey, try deviceIdentity.signingPublicKeyRawRepresentation())
  }

  func testTrustedDeviceStorePersistsCommandTrust() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileURL = directory.appendingPathComponent("trusted-mobile-devices.json")
    let identity = MobileDeviceIdentity(id: "device-phone", displayName: "Phone")
    let device = MobilePairingTrustedDevice(
      stationID: "station-mac-studio",
      deviceID: identity.id,
      displayName: identity.displayName,
      signingKeyFingerprint: try identity.signingKeyFingerprint(),
      signingPublicKeyRawRepresentation: try identity.signingPublicKeyRawRepresentation(),
      agreementPublicKeyRawRepresentation: try identity.agreementPublicKeyRawRepresentation(),
      snapshotKeyID: "snapshot-key",
      commandKeyID: "command-key",
      symmetricKeyRawRepresentation: Data(repeating: 9, count: 32),
      pairedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let writer = try MobileMacTrustedCommandDeviceStore(fileURL: fileURL)
    try await writer.trust(device)
    let reader = try MobileMacTrustedCommandDeviceStore(fileURL: fileURL)

    let publicSigningKey = try await reader.publicSigningKey(
      actorDeviceID: identity.id,
      signingKeyFingerprint: try identity.signingKeyFingerprint()
    )
    let trustedDevices = try await reader.trustedDevices()

    XCTAssertEqual(publicSigningKey, try identity.signingPublicKeyRawRepresentation())
    XCTAssertEqual(trustedDevices, [device])
  }
}

private struct FixedSnapshotSource: MobileMirrorSnapshotSource {
  let snapshot: MobileMirrorSnapshot

  func makeSnapshot(now: Date) async throws -> MobileMirrorSnapshot {
    snapshot
  }
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
