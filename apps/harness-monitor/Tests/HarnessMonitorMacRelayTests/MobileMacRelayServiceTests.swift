import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto
import HarnessMonitorKit
import HarnessMonitorMacRelay
import XCTest

final class MobileMacRelayServiceTests: XCTestCase {
  func testRelayRedactsQueuedCommandFieldsInPublishedMirrorOnly() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = MobileDemoFixtures.snapshot(now: now)
    let stationID = "station-mac-studio"
    let commandTarget = MobileCommandTarget(
      stationID: stationID,
      sessionID: "session-alpha",
      agentID: "agent-codex",
      targetRevision: snapshot.revision
    )
    var queuedCommand = command(
      kind: .agentPrompt,
      target: commandTarget,
      payload: ["prompt": "Bearer abcdefghijklmnopqrstuvwxyz1234567890"]
    )
    queuedCommand.title = "Prompt password=commandtitle"
    queuedCommand.confirmationText = "Send OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwxyz123456"
    queuedCommand.auditReason = "client_secret=auditsecret"
    let queue = InMemoryMobileRelayCommandQueue(commands: [queuedCommand])
    let snapshotSink = RecordingMobileMirrorSnapshotSink()
    let client = RecordingMobileRelayCommandClient()
    let relay = MobileMacRelayService(
      stationID: stationID,
      snapshotSource: FixedSnapshotSource(snapshot: snapshot),
      snapshotSink: snapshotSink,
      commandQueue: queue,
      executor: HarnessMonitorClientMobileRelayCommandExecutor(
        client: client,
        now: { now }
      )
    )

    _ = try await relay.executePendingCommands(now: now)
    let publishedSnapshots = await snapshotSink.snapshots()
    let publishedSnapshot = try XCTUnwrap(publishedSnapshots.last)
    let publishedJSON = try XCTUnwrap(
      String(data: JSONEncoder().encode(publishedSnapshot), encoding: .utf8)
    )
    let recordedEvents = await client.events()

    XCTAssertEqual(
      recordedEvents,
      ["prompt-agent:agent-codex:Bearer abcdefghijklmnopqrstuvwxyz1234567890"]
    )
    for forbidden in [
      "commandtitle",
      "sk-abcdefghijklmnopqrstuvwxyz123456",
      "auditsecret",
      "abcdefghijklmnopqrstuvwxyz1234567890",
    ] {
      XCTAssertFalse(publishedJSON.contains(forbidden), "Published mirror leaked \(forbidden)")
    }
    XCTAssertEqual(publishedSnapshot.commands.first?.title, "Prompt password=[redacted]")
    XCTAssertEqual(
      publishedSnapshot.commands.first?.confirmationText,
      "Send OPENAI_API_KEY=[redacted]"
    )
    XCTAssertEqual(publishedSnapshot.commands.first?.auditReason, "client_secret=[redacted]")
    XCTAssertEqual(publishedSnapshot.commands.first?.payload["prompt"], "Bearer [redacted]")
  }

  func testRelayRedactsExecutorSuccessReceiptsBeforeRecording() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = MobileDemoFixtures.snapshot(now: now)
    let stationID = "station-mac-studio"
    var queuedCommand = command(
      kind: .refresh,
      target: MobileCommandTarget(
        stationID: stationID,
        targetRevision: snapshot.revision
      ),
      payload: ["scope": "mobileMirror"]
    )
    queuedCommand.confirmationText = "Refresh TOKEN=receiptrequest"
    let queue = InMemoryMobileRelayCommandQueue(commands: [queuedCommand])
    let relay = MobileMacRelayService(
      stationID: stationID,
      snapshotSource: FixedSnapshotSource(snapshot: snapshot),
      commandQueue: queue,
      executor: SecretSucceedingMobileRelayCommandExecutor(
        message: "Finished with password=receiptsuccess and Bearer successsecret"
      )
    )

    let receipts = try await relay.executePendingCommands(now: now)
    let recordedReceipts = await queue.receipts
    let terminalReceipt = try XCTUnwrap(recordedReceipts.last)

    XCTAssertEqual(receipts.first?.message, "Finished with password=[redacted] and Bearer [redacted]")
    XCTAssertEqual(terminalReceipt.message, receipts.first?.message)
    XCTAssertFalse(terminalReceipt.message.contains("receiptsuccess"))
    XCTAssertFalse(terminalReceipt.message.contains("successsecret"))
  }

  func testRelayRedactsExecutorFailureReceiptsBeforeRecording() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = MobileDemoFixtures.snapshot(now: now)
    let stationID = "station-mac-studio"
    let queuedCommand = command(
      kind: .refresh,
      target: MobileCommandTarget(
        stationID: stationID,
        targetRevision: snapshot.revision
      ),
      payload: ["scope": "mobileMirror"]
    )
    let queue = InMemoryMobileRelayCommandQueue(commands: [queuedCommand])
    let relay = MobileMacRelayService(
      stationID: stationID,
      snapshotSource: FixedSnapshotSource(snapshot: snapshot),
      commandQueue: queue,
      executor: SecretFailingMobileRelayCommandExecutor(
        message: "Daemon rejected api_key=receiptfailure"
      )
    )

    let receipts = try await relay.executePendingCommands(now: now)
    let recordedReceipts = await queue.receipts
    let terminalReceipt = try XCTUnwrap(recordedReceipts.last)

    XCTAssertEqual(receipts.first?.status, .failed)
    XCTAssertEqual(terminalReceipt.status, .failed)
    XCTAssertTrue(terminalReceipt.message.contains("api_key=[redacted]"))
    XCTAssertFalse(terminalReceipt.message.contains("receiptfailure"))
  }

  func testRelayConsumesCloudMirrorQueueAndWritesEncryptedReceipt() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = MobileDemoFixtures.snapshot(now: now)
    let stationID = "station-mac-studio"
    let database = InMemoryMobileCloudMirrorDatabase()
    let cipher = MobilePayloadCipher(rawKey: Data(repeating: 15, count: 32))
    let identity = MobileDeviceIdentity(id: "device-phone", displayName: "Phone")
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
    let relayQueue = try makeReceiptRelayQueue(
      database: database,
      identity: identity,
      stationID: stationID,
      now: now
    )
    let relay = MobileMacRelayService(
      stationID: stationID,
      snapshotSource: FixedSnapshotSource(snapshot: snapshot),
      commandQueue: relayQueue,
      executor: EchoMobileRelayCommandExecutor()
    )

    let receipts = try await relay.executePendingCommands(now: now)
    let restartedRelay = MobileMacRelayService(
      stationID: stationID,
      snapshotSource: FixedSnapshotSource(snapshot: snapshot),
      commandQueue: relayQueue,
      executor: EchoMobileRelayCommandExecutor()
    )
    let restartedReceipts = try await restartedRelay.executePendingCommands(
      now: now.addingTimeInterval(1)
    )
    let receiptRecord = try await database.fetch(recordID: "receipt-\(command.id)")
    let acceptedReceiptRecord = try await database.fetch(recordID: "receipt-\(command.id)-accepted")
    let runningReceiptRecord = try await database.fetch(recordID: "receipt-\(command.id)-running")
    let storedReceipt: MobileCommandReceipt = try cipher.open(
      try XCTUnwrap(receiptRecord?.envelope)
    )
    let acceptedReceipt: MobileCommandReceipt = try cipher.open(
      try XCTUnwrap(acceptedReceiptRecord?.envelope)
    )
    let runningReceipt: MobileCommandReceipt = try cipher.open(
      try XCTUnwrap(runningReceiptRecord?.envelope)
    )

    XCTAssertEqual(receipts.count, 1)
    XCTAssertEqual(receipts.first?.status, .succeeded)
    XCTAssertEqual(restartedReceipts, [])
    XCTAssertEqual(acceptedReceipt.status, .accepted)
    XCTAssertEqual(runningReceipt.status, .running)
    XCTAssertEqual(storedReceipt.commandID, command.id)
    XCTAssertEqual(receiptRecord?.metadata.type, .receipt)
  }

  func testRelayWritesEncryptedSnapshotForTrustedMobileDevices() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = MobileDemoFixtures.snapshot(now: now)
    let stationID = "station-mac-studio"
    let database = InMemoryMobileCloudMirrorDatabase()
    let trustedDevice = MobilePairingTrustedDevice(
      stationID: stationID,
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
    let trustedDeviceStore = try MobileMacTrustedCommandDeviceStore(devices: [trustedDevice])
    let snapshotSink = MobileCloudMirrorRelaySnapshotSink(
      stationID: stationID,
      writer: MobileCloudMirrorSnapshotWriter(database: database),
      trustedDeviceStore: trustedDeviceStore,
      now: { now }
    )
    let relay = MobileMacRelayService(
      stationID: stationID,
      snapshotSource: FixedSnapshotSource(snapshot: snapshot),
      snapshotSink: snapshotSink,
      commandQueue: InMemoryMobileRelayCommandQueue(commands: []),
      executor: EchoMobileRelayCommandExecutor()
    )

    let receipts = try await relay.executePendingCommands(now: now)
    let record = try await database.fetch(
      recordID: MobileCloudMirrorSnapshotWriter.snapshotRecordID(
        stationID: stationID,
        device: trustedDevice
      )
    )
    let opened: MobileMirrorSnapshot = try MobilePayloadCipher(
      rawKey: trustedDevice.symmetricKeyRawRepresentation
    )
    .open(try XCTUnwrap(record?.envelope))
    var expectedSnapshot = snapshot
    expectedSnapshot.commands = []
    expectedSnapshot.stations = snapshot.stations.map { station in
      guard station.id == stationID else {
        return station
      }
      var updatedStation = station
      updatedStation.commandQueueCount = 0
      return updatedStation
    }

    XCTAssertEqual(receipts, [])
    XCTAssertEqual(opened, expectedSnapshot)
    XCTAssertEqual(record?.metadata.type, .snapshot)
  }

  func testRelayCanPublishSnapshotBeforeCommandExecution() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = MobileDemoFixtures.snapshot(now: now)
    var command = try XCTUnwrap(snapshot.commands.first { $0.status == .queued })
    let stationID = command.stationID
    command.target.targetRevision = snapshot.revision
    let database = InMemoryMobileCloudMirrorDatabase()
    let trustedDevice = MobilePairingTrustedDevice(
      stationID: stationID,
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
    let trustedDeviceStore = try MobileMacTrustedCommandDeviceStore(devices: [trustedDevice])
    let snapshotSink = MobileCloudMirrorRelaySnapshotSink(
      stationID: stationID,
      writer: MobileCloudMirrorSnapshotWriter(database: database),
      trustedDeviceStore: trustedDeviceStore,
      now: { now }
    )
    let queue = InMemoryMobileRelayCommandQueue(commands: [command])
    let relay = MobileMacRelayService(
      stationID: stationID,
      snapshotSource: FixedSnapshotSource(snapshot: snapshot),
      snapshotSink: snapshotSink,
      commandQueue: queue,
      executor: EchoMobileRelayCommandExecutor()
    )

    let mirroredSnapshot = try await relay.publishSnapshot(now: now)
    let record = try await database.fetch(
      recordID: MobileCloudMirrorSnapshotWriter.snapshotRecordID(
        stationID: stationID,
        device: trustedDevice
      )
    )
    let opened: MobileMirrorSnapshot = try MobilePayloadCipher(
      rawKey: trustedDevice.symmetricKeyRawRepresentation
    )
    .open(try XCTUnwrap(record?.envelope))
    let pendingCommands = try await queue.pendingCommands(stationID: stationID)
    let receipts = await queue.receipts

    XCTAssertEqual(mirroredSnapshot.commands.map(\.id), [command.id])
    XCTAssertEqual(opened.commands.map(\.id), [command.id])
    XCTAssertEqual(opened.station(id: stationID)?.commandQueueCount, 1)
    XCTAssertEqual(pendingCommands.map(\.id), [command.id])
    XCTAssertEqual(receipts, [])
  }

  func testRelayTreatsMissingCloudKitSchemaAsEmptyTick() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = MobileDemoFixtures.snapshot(now: now)
    var command = snapshot.commands.first { $0.status == .queued }!
    let stationID = command.stationID
    command.target.targetRevision = snapshot.revision
    let queue = InMemoryMobileRelayCommandQueue(commands: [command])
    let relay = MobileMacRelayService(
      stationID: stationID,
      snapshotSource: FixedSnapshotSource(snapshot: snapshot),
      snapshotSink: MissingCloudKitSchemaSnapshotSink(),
      commandQueue: queue,
      executor: EchoMobileRelayCommandExecutor()
    )

    let receipts = try await relay.executePendingCommands(now: now)
    let pendingCommands = try await queue.pendingCommands(stationID: stationID)

    XCTAssertEqual(receipts, [])
    XCTAssertEqual(pendingCommands.map(\.id), [command.id])
  }

  private func makeReceiptRelayQueue(
    database: InMemoryMobileCloudMirrorDatabase,
    identity: MobileDeviceIdentity,
    stationID: String,
    now: Date
  ) throws -> MobileCloudMirrorRelayCommandQueue {
    MobileCloudMirrorRelayCommandQueue(
      commandQueue: MobileCloudMirrorCommandQueue(
        database: database,
        trustedDeviceStore: MobileRelayPairingCommandTrustStore(devices: [
          MobilePairingTrustedDevice(
            stationID: stationID,
            deviceID: identity.id,
            displayName: identity.displayName,
            signingKeyFingerprint: try identity.signingKeyFingerprint(),
            signingPublicKeyRawRepresentation: try identity.signingPublicKeyRawRepresentation(),
            agreementPublicKeyRawRepresentation:
              try identity.agreementPublicKeyRawRepresentation(),
            snapshotKeyID: "snapshot-key",
            commandKeyID: "command-key",
            symmetricKeyRawRepresentation: Data(repeating: 15, count: 32),
            pairedAt: now
          )
        ])
      ),
      receiptKeyID: "receipt-key",
      now: { now }
    )
  }
}
