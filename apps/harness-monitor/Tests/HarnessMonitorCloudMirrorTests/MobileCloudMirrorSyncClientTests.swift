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

  func testFetchLatestSnapshotFallsBackWhenDirectDeviceRecordIsStale() async throws {
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
    var staleDirectSnapshot = MobileDemoFixtures.snapshot(now: now.addingTimeInterval(-120))
    staleDirectSnapshot.revision = 1
    var activeSnapshot = MobileDemoFixtures.snapshot(now: now)
    activeSnapshot.revision = 2
    let directMetadata = MobileMirrorRecordMetadata(
      id: MobileCloudMirrorSnapshotWriter.snapshotRecordID(
        stationID: "station-mac-studio",
        deviceID: identity.id,
        signingKeyFingerprint: try identity.signingKeyFingerprint()
      ),
      type: .snapshot,
      stationID: "station-mac-studio",
      revision: staleDirectSnapshot.revision,
      updatedAt: now.addingTimeInterval(-120),
      expiresAt: now.addingTimeInterval(-1)
    )
    let directEnvelope = try cipher.seal(
      staleDirectSnapshot,
      keyID: "snapshot-key",
      additionalAuthenticatedData: MobileCloudMirrorRecordAAD.data(for: directMetadata),
      createdAt: now.addingTimeInterval(-120)
    )
    try await database.save(MobileMirrorRecord(metadata: directMetadata, envelope: directEnvelope))
    try await cloudMirrorSaveSnapshot(
      activeSnapshot,
      id: "snapshot-active-fallback",
      cipher: cipher,
      database: database,
      now: now
    )

    let fetched = try await client.fetchLatestSnapshot(
      stationID: "station-mac-studio",
      now: now
    )

    XCTAssertEqual(fetched, activeSnapshot)
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

  func testFetchLatestSnapshotDoesNotDowngradeTerminalReceiptWithLateNonterminalReceipt()
    async throws
  {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let database = InMemoryMobileCloudMirrorDatabase()
    let cipher = MobilePayloadCipher(rawKey: Data(repeating: 28, count: 32))
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
      id: "command-terminal",
      risk: .high,
      targetRevision: snapshot.revision,
      now: now
    )
    let succeededReceipt = MobileCommandReceipt(
      commandID: command.id,
      stationID: command.stationID,
      status: .succeeded,
      message: "Approved from Mac relay.",
      receivedAt: now.addingTimeInterval(2),
      completedAt: now.addingTimeInterval(2),
      executionRevision: snapshot.revision
    )
    let lateRunningReceipt = MobileCommandReceipt(
      commandID: command.id,
      stationID: command.stationID,
      status: .running,
      message: "Delayed running receipt.",
      receivedAt: now.addingTimeInterval(3),
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
      succeededReceipt,
      keyID: "command-key",
      now: now.addingTimeInterval(2)
    )
    _ = try await commandQueue.recordReceipt(
      lateRunningReceipt,
      keyID: "command-key",
      now: now.addingTimeInterval(3)
    )

    let fetched = try await client.fetchLatestSnapshot(
      stationID: "station-mac-studio",
      now: now.addingTimeInterval(4)
    )
    let fetchedCommand = try XCTUnwrap(fetched?.commands.first)

    XCTAssertEqual(fetchedCommand.status, .succeeded)
    XCTAssertEqual(fetchedCommand.receipt, succeededReceipt)
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

  func cloudMirrorMakeCommand(
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

  func cloudMirrorSaveSnapshot(
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
