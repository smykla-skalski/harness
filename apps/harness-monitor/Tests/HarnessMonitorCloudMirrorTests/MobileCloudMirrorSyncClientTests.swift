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
    XCTAssertEqual(queued.signedCommand.command.status, .queued)
    XCTAssertEqual(queued.signedCommand.command.actorDeviceID, identity.id)

    let opened: MobileSignedCommand = try XCTUnwrap(queued.record.envelope).open(using: cipher)
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
}

extension MobileEncryptedEnvelope {
  fileprivate func open(using cipher: MobilePayloadCipher) throws -> MobileSignedCommand {
    try cipher.open(self)
  }
}
