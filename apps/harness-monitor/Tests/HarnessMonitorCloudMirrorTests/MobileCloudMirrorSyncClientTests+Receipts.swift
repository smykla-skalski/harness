import CloudKit
import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto
import XCTest

extension MobileCloudMirrorSyncClientTests {
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
}
