import CloudKit
import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto
import XCTest

final class MobileCloudMirrorSnapshotWriterTests: XCTestCase {
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

  func testSnapshotWriterChunksOversizedSnapshotAndSyncClientReassembles() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let database = InMemoryMobileCloudMirrorDatabase()
    let writer = MobileCloudMirrorSnapshotWriter(
      database: database,
      snapshotCiphertextChunkSize: 512
    )
    let symmetricKey = Data(repeating: 13, count: 32)
    let device = MobilePairingTrustedDevice(
      stationID: "station-mac-studio",
      deviceID: "device-phone",
      displayName: "Phone",
      signingKeyFingerprint: "AA:BB:CC:DD",
      signingPublicKeyRawRepresentation: Data([1]),
      agreementPublicKeyRawRepresentation: Data([2]),
      snapshotKeyID: "snapshot-key",
      commandKeyID: "command-key",
      symmetricKeyRawRepresentation: symmetricKey,
      pairedAt: now
    )
    var snapshot = MobileDemoFixtures.snapshot(now: now)
    snapshot.revision = 99
    snapshot.taskBoardItems.append(
      MobileTaskBoardSummary(
        id: "task-large",
        stationID: "station-mac-studio",
        title: "Large mirrored task",
        bodyPreview: String(repeating: "review the mirrored payload ", count: 300),
        status: "plan_review",
        statusTitle: "Plan Review",
        priority: "high",
        priorityTitle: "High",
        agentMode: "planning",
        needsYou: true,
        updatedAt: now
      )
    )

    let records = try await writer.writeSnapshot(
      snapshot,
      stationID: "station-mac-studio",
      devices: [device],
      now: now
    )
    let parent = try XCTUnwrap(records.first { $0.metadata.type == .snapshot })
    let chunkRecords = records.filter { $0.metadata.type == .snapshotChunk }
    let client = MobileCloudMirrorSyncClient(
      database: database,
      cipher: MobilePayloadCipher(rawKey: symmetricKey),
      deviceIdentity: MobileDeviceIdentity(id: "device-phone", displayName: "Phone"),
      commandKeyID: "command-key"
    )

    XCTAssertFalse(parent.metadata.chunkIDs.isEmpty)
    XCTAssertEqual(parent.envelope?.ciphertext.count, 1)
    XCTAssertEqual(chunkRecords.map(\.id), parent.metadata.chunkIDs)
    XCTAssertTrue(chunkRecords.allSatisfy { $0.envelope?.ciphertext.isEmpty == false })
    let fetched = try await client.fetchLatestSnapshot(stationID: "station-mac-studio", now: now)
    XCTAssertEqual(fetched, snapshot)
  }

  func testSnapshotWriterRetriesWithSmallerChunksWhenCloudKitRejectsLargeRecords() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let database = SizeLimitedMobileCloudMirrorDatabase(maxCiphertextBytes: 16 * 1024)
    let writer = MobileCloudMirrorSnapshotWriter(
      database: database,
      snapshotCiphertextChunkSize: 64 * 1024
    )
    let symmetricKey = Data(repeating: 13, count: 32)
    let device = MobilePairingTrustedDevice(
      stationID: "station-mac-studio",
      deviceID: "device-phone",
      displayName: "Phone",
      signingKeyFingerprint: "AA:BB:CC:DD",
      signingPublicKeyRawRepresentation: Data([1]),
      agreementPublicKeyRawRepresentation: Data([2]),
      snapshotKeyID: "snapshot-key",
      commandKeyID: "command-key",
      symmetricKeyRawRepresentation: symmetricKey,
      pairedAt: now
    )
    var snapshot = MobileDemoFixtures.snapshot(now: now)
    snapshot.revision = 100
    snapshot.taskBoardItems.append(
      MobileTaskBoardSummary(
        id: "task-too-large-for-first-chunk",
        stationID: "station-mac-studio",
        title: "Large mirrored task",
        bodyPreview: String(repeating: "large mirrored payload ", count: 5_000),
        status: "plan_review",
        statusTitle: "Plan Review",
        priority: "high",
        priorityTitle: "High",
        agentMode: "planning",
        needsYou: true,
        updatedAt: now
      )
    )

    let records = try await writer.writeSnapshot(
      snapshot,
      stationID: "station-mac-studio",
      devices: [device],
      now: now
    )
    let savedRecords = await database.savedRecords()
    let parent = try XCTUnwrap(records.first { $0.metadata.type == .snapshot })
    let client = MobileCloudMirrorSyncClient(
      database: database,
      cipher: MobilePayloadCipher(rawKey: symmetricKey),
      deviceIdentity: MobileDeviceIdentity(id: "device-phone", displayName: "Phone"),
      commandKeyID: "command-key"
    )
    let fetched = try await client.fetchLatestSnapshot(
      stationID: "station-mac-studio",
      now: now
    )

    XCTAssertFalse(parent.metadata.chunkIDs.isEmpty)
    XCTAssertTrue(savedRecords.allSatisfy { record in
      (record.envelope?.ciphertext.count ?? 0) <= 16 * 1024
    })
    XCTAssertEqual(fetched, snapshot)
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
    let command = writerMakeCommand(
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

  func testQueueCommandCanUseDelegatedActorDeviceID() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let database = InMemoryMobileCloudMirrorDatabase()
    let cipher = MobilePayloadCipher(rawKey: Data(repeating: 8, count: 32))
    let identity = MobileDeviceIdentity(id: "device-phone", displayName: "Phone")
    let watchActorID = MobileCommandActorDeviceID.watchActorID(baseDeviceID: identity.id)
    let client = MobileCloudMirrorSyncClient(
      database: database,
      cipher: cipher,
      deviceIdentity: identity,
      actorDeviceID: watchActorID,
      commandKeyID: "command-key"
    )
    let command = writerMakeCommand(
      id: "command-watch-approve",
      risk: .high,
      targetRevision: 42,
      now: now
    )

    let queued = try await client.queueCommand(command, currentRevision: 42, now: now)

    XCTAssertEqual(queued.signedCommand.command.actorDeviceID, watchActorID)
    XCTAssertEqual(MobileCommandActorDeviceID.trustedBaseDeviceID(for: watchActorID), identity.id)
    XCTAssertTrue(
      try MobileCommandSigner.verify(
        queued.signedCommand,
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
    let command = writerMakeCommand(
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

  private func writerMakeCommand(
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
