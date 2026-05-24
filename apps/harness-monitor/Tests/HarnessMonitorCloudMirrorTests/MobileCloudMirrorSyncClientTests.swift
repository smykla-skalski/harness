import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto
import XCTest

final class MobileCloudMirrorSyncClientTests: XCTestCase {
  func testFetchLatestSnapshotDecryptsNewestActiveSnapshot() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let database = InMemoryMobileCloudMirrorDatabase()
    let cipher = MobilePayloadCipher(rawKey: Data(repeating: 7, count: 32))
    let identity = MobileDeviceIdentity(id: "device-phone", displayName: "Phone")
    let client = MobileCloudMirrorSyncClient(
      database: database,
      cipher: cipher,
      deviceIdentity: identity,
      commandKeyID: "station-key"
    )
    let snapshot = MobileDemoFixtures.snapshot(now: now)
    let metadata = MobileMirrorRecordMetadata(
      id: "snapshot-station-mac-studio",
      type: .snapshot,
      stationID: "station-mac-studio",
      revision: snapshot.revision,
      updatedAt: now,
      expiresAt: now.addingTimeInterval(60)
    )
    let envelope = try cipher.seal(
      snapshot,
      keyID: "station-key",
      additionalAuthenticatedData: MobileCloudMirrorRecordAAD.data(for: metadata),
      createdAt: now
    )
    try await database.save(MobileMirrorRecord(metadata: metadata, envelope: envelope))

    let fetched = try await client.fetchLatestSnapshot(
      stationID: "station-mac-studio",
      now: now
    )

    XCTAssertEqual(fetched, snapshot)
  }

  func testFetchLatestSnapshotSkipsRecordsForOtherPairedDevices() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let database = InMemoryMobileCloudMirrorDatabase()
    let phoneCipher = MobilePayloadCipher(rawKey: Data(repeating: 7, count: 32))
    let watchCipher = MobilePayloadCipher(rawKey: Data(repeating: 8, count: 32))
    let identity = MobileDeviceIdentity(id: "device-phone", displayName: "Phone")
    let client = MobileCloudMirrorSyncClient(
      database: database,
      cipher: phoneCipher,
      deviceIdentity: identity,
      commandKeyID: "station-key"
    )
    let phoneSnapshot = MobileDemoFixtures.snapshot(now: now)
    var watchSnapshot = MobileDemoFixtures.snapshot(now: now.addingTimeInterval(1))
    watchSnapshot.revision = phoneSnapshot.revision + 1

    try await saveSnapshot(
      watchSnapshot,
      id: "snapshot-watch",
      cipher: watchCipher,
      database: database,
      now: now.addingTimeInterval(1)
    )
    try await saveSnapshot(
      phoneSnapshot,
      id: "snapshot-phone",
      cipher: phoneCipher,
      database: database,
      now: now
    )

    let fetched = try await client.fetchLatestSnapshot(
      stationID: "station-mac-studio",
      now: now
    )

    XCTAssertEqual(fetched, phoneSnapshot)
  }

  func testFetchLatestSnapshotMergesDecryptableCommandReceipts() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let database = InMemoryMobileCloudMirrorDatabase()
    let cipher = MobilePayloadCipher(rawKey: Data(repeating: 27, count: 32))
    let identity = MobileDeviceIdentity(id: "device-phone", displayName: "Phone")
    let client = MobileCloudMirrorSyncClient(
      database: database,
      cipher: cipher,
      deviceIdentity: identity,
      commandKeyID: "command-key"
    )
    var snapshot = MobileDemoFixtures.snapshot(now: now)
    snapshot.commands = []
    let command = makeCommand(
      id: "command-approve",
      risk: .high,
      targetRevision: snapshot.revision,
      now: now
    )
    let receipt = MobileCommandReceipt(
      commandID: command.id,
      stationID: command.stationID,
      status: .succeeded,
      message: "Approved from Mac relay.",
      receivedAt: now.addingTimeInterval(2),
      completedAt: now.addingTimeInterval(3),
      executionRevision: snapshot.revision
    )

    try await saveSnapshot(
      snapshot,
      id: "snapshot-phone",
      cipher: cipher,
      database: database,
      now: now
    )
    _ = try await client.queueCommand(command, currentRevision: snapshot.revision, now: now)
    _ = try await MobileCloudMirrorCommandQueue(
      database: database,
      cipher: cipher,
      trustStore: InMemoryMobileCommandTrustStore()
    )
    .recordReceipt(receipt, keyID: "command-key", now: now.addingTimeInterval(3))

    let fetched = try await client.fetchLatestSnapshot(
      stationID: "station-mac-studio",
      now: now.addingTimeInterval(4)
    )
    let fetchedCommand = try XCTUnwrap(fetched?.commands.first)

    XCTAssertEqual(fetched?.commands.count, 1)
    XCTAssertEqual(fetchedCommand.id, command.id)
    XCTAssertEqual(fetchedCommand.status, .succeeded)
    XCTAssertEqual(fetchedCommand.receipt, receipt)
    XCTAssertEqual(fetchedCommand.updatedAt, receipt.completedAt)
    XCTAssertEqual(fetchedCommand.actorDeviceID, identity.id)
  }

  func testSnapshotWriterEncryptsOneOpaqueRecordPerTrustedDevice() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let database = InMemoryMobileCloudMirrorDatabase()
    let writer = MobileCloudMirrorSnapshotWriter(database: database)
    let device = MobilePairingTrustedDevice(
      stationID: "station-mac-studio",
      deviceID: "device-phone",
      displayName: "Phone",
      signingKeyFingerprint: "AA:BB:CC:DD",
      signingPublicKeyRawRepresentation: Data([1]),
      agreementPublicKeyRawRepresentation: Data([2]),
      snapshotKeyID: "snapshot-key",
      commandKeyID: "command-key",
      symmetricKeyRawRepresentation: Data(repeating: 12, count: 32),
      pairedAt: now
    )
    let snapshot = MobileDemoFixtures.snapshot(now: now)

    let records = try await writer.writeSnapshot(
      snapshot,
      stationID: "station-mac-studio",
      devices: [device],
      now: now
    )
    let record = try XCTUnwrap(records.first)
    let fetched = try await database.fetch(recordID: record.id)
    let opened: MobileMirrorSnapshot = try MobilePayloadCipher(
      rawKey: device.symmetricKeyRawRepresentation
    )
    .open(try XCTUnwrap(fetched?.envelope))

    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(opened, snapshot)
    XCTAssertEqual(record.metadata.type, .snapshot)
    XCTAssertFalse(record.id.contains(device.deviceID))
    XCTAssertNil(String(data: record.envelope?.ciphertext ?? Data(), encoding: .utf8))
  }

  func testQueueCommandSignsEncryptsAndPersistsQueuedRecord() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let database = InMemoryMobileCloudMirrorDatabase()
    let cipher = MobilePayloadCipher(rawKey: Data(repeating: 8, count: 32))
    let identity = MobileDeviceIdentity(id: "device-phone", displayName: "Phone")
    let client = MobileCloudMirrorSyncClient(
      database: database,
      cipher: cipher,
      deviceIdentity: identity,
      commandKeyID: "command-key"
    )
    let command = makeCommand(
      id: "command-approve",
      risk: .high,
      targetRevision: 42,
      now: now
    )

    let queued = try await client.queueCommand(command, currentRevision: 42, now: now)
    let stored = try await database.fetch(recordID: command.id)

    XCTAssertEqual(stored, queued.record)
    XCTAssertEqual(queued.record.metadata.type, .command)
    XCTAssertEqual(queued.record.metadata.revision, 42)
    XCTAssertEqual(
      queued.record.metadata.expiresAt,
      now.addingTimeInterval(MobileCloudMirrorSchema.sevenDayRetention)
    )
    XCTAssertEqual(queued.signedCommand.command.status, .queued)
    XCTAssertEqual(queued.signedCommand.command.actorDeviceID, identity.id)
    XCTAssertEqual(queued.signedCommand.command.expiresAt, command.expiresAt)

    let opened: MobileSignedCommand = try cipher.open(try XCTUnwrap(queued.record.envelope))
    XCTAssertEqual(opened, queued.signedCommand)
    XCTAssertTrue(
      try MobileCommandSigner.verify(
        opened,
        publicKeyRawRepresentation: identity.signingPublicKeyRawRepresentation()
      )
    )
  }

  func testQueueCommandRejectsStaleFreshStateBeforeWriting() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let database = InMemoryMobileCloudMirrorDatabase()
    let cipher = MobilePayloadCipher(rawKey: Data(repeating: 9, count: 32))
    let client = MobileCloudMirrorSyncClient(
      database: database,
      cipher: cipher,
      deviceIdentity: MobileDeviceIdentity(id: "device-phone", displayName: "Phone"),
      commandKeyID: "command-key"
    )
    let command = makeCommand(
      id: "command-stale",
      risk: .high,
      targetRevision: 41,
      now: now
    )

    do {
      _ = try await client.queueCommand(command, currentRevision: 42, now: now)
      XCTFail("Expected stale revision rejection")
    } catch let error as MobileCommandValidationError {
      XCTAssertEqual(error, .staleRevision(expected: 41, actual: 42))
    }

    let records = try await database.fetchAll(stationID: command.stationID)
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
    let command = makeCommand(
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

  private func makeCommand(
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

  private func saveSnapshot(
    _ snapshot: MobileMirrorSnapshot,
    id: String,
    cipher: MobilePayloadCipher,
    database: InMemoryMobileCloudMirrorDatabase,
    now: Date
  ) async throws {
    let metadata = MobileMirrorRecordMetadata(
      id: id,
      type: .snapshot,
      stationID: "station-mac-studio",
      revision: snapshot.revision,
      updatedAt: now,
      expiresAt: now.addingTimeInterval(60)
    )
    let envelope = try cipher.seal(
      snapshot,
      keyID: "snapshot-key",
      additionalAuthenticatedData: MobileCloudMirrorRecordAAD.data(for: metadata),
      createdAt: now
    )
    try await database.save(MobileMirrorRecord(metadata: metadata, envelope: envelope))
  }
}
