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

    try await saveSnapshot(
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
    var command = makeCommand(
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
    try await saveSnapshot(
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
    var command = makeCommand(
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
    try await saveSnapshot(
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
    let command = makeCommand(
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
    let command = makeCommand(
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
    let command = makeCommand(
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

  func testCancelCommandRejectsOtherDeviceAndNonQueuedCommands() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let database = InMemoryMobileCloudMirrorDatabase()
    let client = MobileCloudMirrorSyncClient(
      database: database,
      cipher: MobilePayloadCipher(rawKey: Data(repeating: 12, count: 32)),
      deviceIdentity: MobileDeviceIdentity(id: "device-phone", displayName: "Phone"),
      commandKeyID: "command-key"
    )
    var otherDeviceCommand = makeCommand(
      id: "command-other-device",
      risk: .high,
      targetRevision: 42,
      now: now
    )
    otherDeviceCommand.status = .queued
    otherDeviceCommand.actorDeviceID = "device-watch"
    var runningCommand = makeCommand(
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

private actor SizeLimitedMobileCloudMirrorDatabase: MobileCloudMirrorDatabase {
  private let maxCiphertextBytes: Int
  private var records: [String: MobileMirrorRecord] = [:]

  init(maxCiphertextBytes: Int) {
    self.maxCiphertextBytes = maxCiphertextBytes
  }

  func save(_ record: MobileMirrorRecord) async throws {
    if (record.envelope?.ciphertext.count ?? 0) > maxCiphertextBytes {
      throw CKError(.limitExceeded)
    }
    records[record.id] = record
  }

  func fetch(recordID: String) async throws -> MobileMirrorRecord? {
    records[recordID]
  }

  func fetchAll(stationID: String) async throws -> [MobileMirrorRecord] {
    records.values
      .filter { $0.metadata.stationID == stationID }
      .sorted { $0.metadata.updatedAt > $1.metadata.updatedAt }
  }

  func delete(recordID: String) async throws {
    records.removeValue(forKey: recordID)
  }

  func savedRecords() -> [MobileMirrorRecord] {
    records.values.sorted { $0.id < $1.id }
  }
}
