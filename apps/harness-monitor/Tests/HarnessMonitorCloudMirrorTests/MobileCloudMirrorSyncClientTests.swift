import CloudKit
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

    try await cloudMirrorSaveSnapshot(
      watchSnapshot,
      id: "snapshot-watch",
      cipher: watchCipher,
      database: database,
      now: now.addingTimeInterval(1)
    )
    try await cloudMirrorSaveSnapshot(
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
    let command = cloudMirrorMakeCommand(
      id: "command-approve",
      risk: .high,
      targetRevision: snapshot.revision,
      now: now
    )
    let acceptedReceipt = MobileCommandReceipt(
      commandID: command.id,
      stationID: command.stationID,
      status: .accepted,
      message: "Accepted by Mac relay.",
      receivedAt: now.addingTimeInterval(1),
      executionRevision: snapshot.revision
    )
    let runningReceipt = MobileCommandReceipt(
      commandID: command.id,
      stationID: command.stationID,
      status: .running,
      message: "Running on Mac relay.",
      receivedAt: now.addingTimeInterval(2),
      executionRevision: snapshot.revision
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

    try await cloudMirrorSaveSnapshot(
      snapshot,
      id: "snapshot-phone",
      cipher: cipher,
      database: database,
      now: now
    )
    _ = try await client.queueCommand(command, currentRevision: snapshot.revision, now: now)
    let commandQueue = MobileCloudMirrorCommandQueue(
      database: database,
      cipher: cipher,
      trustStore: InMemoryMobileCommandTrustStore()
    )
    _ = try await commandQueue.recordReceipt(
      runningReceipt,
      keyID: "command-key",
      now: now.addingTimeInterval(2)
    )
    _ = try await commandQueue.recordReceipt(
      receipt,
      keyID: "command-key",
      now: now.addingTimeInterval(3)
    )
    _ = try await commandQueue.recordReceipt(
      acceptedReceipt,
      keyID: "command-key",
      now: now.addingTimeInterval(4)
    )

    let fetched = try await client.fetchLatestSnapshot(
      stationID: "station-mac-studio",
      now: now.addingTimeInterval(5)
    )
    let fetchedCommand = try XCTUnwrap(fetched?.commands.first)

    XCTAssertEqual(fetched?.commands.count, 1)
    XCTAssertEqual(fetchedCommand.id, command.id)
    XCTAssertEqual(fetchedCommand.status, .succeeded)
    XCTAssertEqual(fetchedCommand.receipt, receipt)
    XCTAssertEqual(fetchedCommand.updatedAt, receipt.completedAt)
    XCTAssertEqual(fetchedCommand.actorDeviceID, identity.id)
  }

  func testFetchLatestSnapshotSkipsSnapshotWithMismatchedAuthenticatedMetadata()
    async throws
  {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let database = InMemoryMobileCloudMirrorDatabase()
    let cipher = MobilePayloadCipher(rawKey: Data(repeating: 29, count: 32))
    let identity = MobileDeviceIdentity(id: "device-phone", displayName: "Phone")
    let client = MobileCloudMirrorSyncClient(
      database: database,
      cipher: cipher,
      deviceIdentity: identity,
      commandKeyID: "command-key"
    )
    let snapshot = MobileDemoFixtures.snapshot(now: now)
    let storedMetadata = MobileMirrorRecordMetadata(
      id: "snapshot-tampered",
      type: .snapshot,
      stationID: "station-mac-studio",
      revision: snapshot.revision,
      updatedAt: now,
      expiresAt: now.addingTimeInterval(60)
    )
    let authenticatedMetadata = MobileMirrorRecordMetadata(
      id: "snapshot-original",
      type: .snapshot,
      stationID: "station-mac-studio",
      revision: snapshot.revision,
      updatedAt: now,
      expiresAt: now.addingTimeInterval(60)
    )
    let envelope = try cipher.seal(
      snapshot,
      keyID: "snapshot-key",
      additionalAuthenticatedData: MobileCloudMirrorRecordAAD.data(for: authenticatedMetadata),
      createdAt: now
    )
    try await database.save(MobileMirrorRecord(metadata: storedMetadata, envelope: envelope))

    let fetched = try await client.fetchLatestSnapshot(
      stationID: "station-mac-studio",
      now: now
    )

    XCTAssertNil(fetched)
  }

  func testFetchLatestSnapshotSkipsCommandRecordWhenRecordIDDiffersFromSignedCommandID()
    async throws
  {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let database = InMemoryMobileCloudMirrorDatabase()
    let cipher = MobilePayloadCipher(rawKey: Data(repeating: 30, count: 32))
    let identity = MobileDeviceIdentity(id: "device-phone", displayName: "Phone")
    let client = MobileCloudMirrorSyncClient(
      database: database,
      cipher: cipher,
      deviceIdentity: identity,
      commandKeyID: "command-key"
    )
    var snapshot = MobileDemoFixtures.snapshot(now: now)
    snapshot.commands = []
    var command = cloudMirrorMakeCommand(
      id: "command-live",
      risk: .high,
      targetRevision: snapshot.revision,
      now: now
    )
    command.status = .queued
    command.actorDeviceID = identity.id
    command.updatedAt = now
    let signedCommand = try MobileCommandSigner.sign(
      command: command,
      identity: identity,
      signedAt: now
    )
    let metadata = MobileMirrorRecordMetadata(
      id: "command-live-copy",
      type: .command,
      stationID: command.stationID,
      revision: snapshot.revision,
      updatedAt: now,
      expiresAt: now.addingTimeInterval(60)
    )
    let envelope = try cipher.seal(
      signedCommand,
      keyID: "command-key",
      additionalAuthenticatedData: MobileCloudMirrorRecordAAD.data(for: metadata),
      createdAt: now
    )
    try await cloudMirrorSaveSnapshot(
      snapshot,
      id: "snapshot-phone",
      cipher: cipher,
      database: database,
      now: now
    )
    try await database.save(MobileMirrorRecord(metadata: metadata, envelope: envelope))

    let fetched = try await client.fetchLatestSnapshot(
      stationID: "station-mac-studio",
      now: now
    )

    XCTAssertEqual(fetched?.commands, [])
  }

  func testFetchLatestSnapshotIgnoresReceiptsForOtherStations() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let database = InMemoryMobileCloudMirrorDatabase()
    let cipher = MobilePayloadCipher(rawKey: Data(repeating: 31, count: 32))
    let identity = MobileDeviceIdentity(id: "device-phone", displayName: "Phone")
    let client = MobileCloudMirrorSyncClient(
      database: database,
      cipher: cipher,
      deviceIdentity: identity,
      commandKeyID: "command-key"
    )
    var snapshot = MobileDemoFixtures.snapshot(now: now)
    var command = cloudMirrorMakeCommand(
      id: "command-receipt-station",
      risk: .high,
      targetRevision: snapshot.revision,
      now: now
    )
    command.status = .queued
    command.actorDeviceID = identity.id
    command.updatedAt = now
    snapshot.commands = [command]
    let wrongStationReceipt = MobileCommandReceipt(
      commandID: command.id,
      stationID: "station-other",
      status: .succeeded,
      message: "Succeeded elsewhere.",
      receivedAt: now.addingTimeInterval(1),
      completedAt: now.addingTimeInterval(2),
      executionRevision: snapshot.revision
    )
    let receiptMetadata = MobileMirrorRecordMetadata(
      id: "receipt-\(command.id)",
      type: .receipt,
      stationID: command.stationID,
      revision: snapshot.revision,
      updatedAt: now.addingTimeInterval(2),
      expiresAt: now.addingTimeInterval(60)
    )
    let receiptEnvelope = try cipher.seal(
      wrongStationReceipt,
      keyID: "command-key",
      additionalAuthenticatedData: MobileCloudMirrorRecordAAD.data(for: receiptMetadata),
      createdAt: now
    )
    try await cloudMirrorSaveSnapshot(
      snapshot,
      id: "snapshot-phone",
      cipher: cipher,
      database: database,
      now: now
    )
    try await database.save(
      MobileMirrorRecord(metadata: receiptMetadata, envelope: receiptEnvelope)
    )

    let fetched = try await client.fetchLatestSnapshot(
      stationID: "station-mac-studio",
      now: now.addingTimeInterval(3)
    )
    let fetchedCommand = try XCTUnwrap(fetched?.commands.first)

    XCTAssertEqual(fetchedCommand.status, .queued)
    XCTAssertNil(fetchedCommand.receipt)
  }

  private func cloudMirrorMakeCommand(
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

  private func cloudMirrorSaveSnapshot(
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
