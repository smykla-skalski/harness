import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto
import HarnessMonitorKit
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

  func testAPIBackedExecutorDispatchesCommandFamilies() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = MobileDemoFixtures.snapshot(now: now)
    let client = RecordingMobileRelayCommandClient()
    let executor = HarnessMonitorClientMobileRelayCommandExecutor(
      client: client,
      now: { now }
    )

    _ = try await executor.execute(
      command(
        kind: .acpPermissionDecision,
        target: MobileCommandTarget(
          stationID: "station-mac-studio",
          agentID: "agent-codex-7",
          targetRevision: snapshot.revision
        ),
        payload: ["batchID": "batch-1", "decision": "approve_all"]
      ),
      snapshot: snapshot
    )
    _ = try await executor.execute(
      command(
        kind: .taskBoardDispatch,
        target: MobileCommandTarget(
          stationID: "station-mac-studio",
          taskID: "task-16",
          targetRevision: snapshot.revision
        ),
        payload: ["status": "todo", "dryRun": "false", "projectDir": "/repo"]
      ),
      snapshot: snapshot
    )
    _ = try await executor.execute(
      command(
        kind: .taskBoardPlanApproval,
        target: MobileCommandTarget(
          stationID: "station-mac-studio",
          taskID: "task-16",
          targetRevision: snapshot.revision
        ),
        payload: ["approvedBy": "watch"]
      ),
      snapshot: snapshot
    )
    _ = try await executor.execute(
      command(
        kind: .agentStart,
        target: MobileCommandTarget(
          stationID: "station-mac-studio",
          sessionID: "session-pr-review",
          taskID: "task-16",
          targetRevision: snapshot.revision
        ),
        payload: ["agent": "codex", "prompt": "Pick up the task", "role": "worker"]
      ),
      snapshot: snapshot
    )
    _ = try await executor.execute(
      command(
        kind: .agentPrompt,
        target: MobileCommandTarget(
          stationID: "station-mac-studio",
          agentID: "agent-codex-7",
          targetRevision: snapshot.revision
        ),
        payload: ["prompt": "Please summarize status."]
      ),
      snapshot: snapshot
    )
    _ = try await executor.execute(
      command(
        kind: .agentStop,
        target: MobileCommandTarget(
          stationID: "station-mac-studio",
          agentID: "agent-codex-7",
          targetRevision: snapshot.revision
        )
      ),
      snapshot: snapshot
    )
    _ = try await executor.execute(
      command(
        kind: .pullRequestMerge,
        target: MobileCommandTarget(
          stationID: "station-mac-studio",
          reviewID: "review-812",
          targetRevision: snapshot.revision
        ),
        payload: ["method": "squash", "headSha": "abc123"]
      ),
      snapshot: snapshot
    )
    _ = try await executor.execute(
      command(
        kind: .pullRequestLabel,
        target: MobileCommandTarget(
          stationID: "station-mac-studio",
          reviewID: "review-812",
          targetRevision: snapshot.revision
        ),
        payload: ["label": "ready"]
      ),
      snapshot: snapshot
    )
    _ = try await executor.execute(
      command(
        kind: .pullRequestRerunChecks,
        target: MobileCommandTarget(
          stationID: "station-mac-studio",
          reviewID: "review-812",
          targetRevision: snapshot.revision
        )
      ),
      snapshot: snapshot
    )
    _ = try await executor.execute(
      command(
        kind: .pullRequestApprove,
        target: MobileCommandTarget(
          stationID: "station-mac-studio",
          reviewID: "review-812",
          targetRevision: snapshot.revision
        )
      ),
      snapshot: snapshot
    )
    _ = try await executor.execute(
      command(
        kind: .refresh,
        target: MobileCommandTarget(
          stationID: "station-mac-studio",
          reviewID: "review-812",
          targetRevision: snapshot.revision
        ),
        payload: ["scope": "reviews"]
      ),
      snapshot: snapshot
    )

    let events = await client.events()
    XCTAssertEqual(
      events,
      [
        "acp:agent-codex-7:batch-1:approveAll",
        "dispatch:task-16:todo:false:/repo",
        "approve-plan:task-16:watch",
        "start-agent:session-pr-review:codex:Pick up the task",
        "prompt-agent:agent-codex-7:Please summarize status.",
        "stop-agent:agent-codex-7",
        "merge-pr:smykla-skalski/harness#812:squash:abc123",
        "label-pr:smykla-skalski/harness#812:ready",
        "rerun-pr:smykla-skalski/harness#812",
        "approve-pr:smykla-skalski/harness#812",
        "refresh:reviews:smykla-skalski/harness#812",
      ]
    )
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

private func command(
  kind: MobileCommandKind,
  target: MobileCommandTarget,
  payload: [String: String] = [:]
) -> MobileCommandRecord {
  let now = Date(timeIntervalSince1970: 1_700_000_000)
  return MobileCommandRecord(
    id: "command-\(kind.rawValue)-\(UUID().uuidString)",
    stationID: target.stationID,
    kind: kind,
    risk: kind == .pullRequestMerge ? .destructive : .high,
    status: .queued,
    title: kind.title,
    confirmationText: kind.title,
    auditReason: kind == .pullRequestMerge ? "Confirmed from test." : nil,
    target: target,
    payload: payload,
    actorDeviceID: "device-phone",
    createdAt: now,
    expiresAt: now.addingTimeInterval(60),
    updatedAt: now
  )
}

private actor RecordingMobileRelayCommandClient: MobileRelayCommandClient {
  private var recordedEvents: [String] = []

  func events() -> [String] {
    recordedEvents
  }

  func resolveAcpPermission(
    agentID: String,
    batchID: String,
    decision: AcpPermissionDecision
  ) async throws -> String {
    recordedEvents.append("acp:\(agentID):\(batchID):\(decision.eventValue)")
    return "ACP resolved."
  }

  func dispatchTaskBoard(_ request: TaskBoardDispatchRequest) async throws -> String {
    recordedEvents.append(
      "dispatch:\(request.itemId ?? ""):\(request.status?.rawValue ?? ""):\(request.dryRun):\(request.projectDir ?? "")"
    )
    return "Task dispatched."
  }

  func approveTaskBoardPlan(
    id: String,
    request: TaskBoardPlanApproveRequest
  ) async throws -> String {
    recordedEvents.append("approve-plan:\(id):\(request.approvedBy)")
    return "Plan approved."
  }

  func startAgent(sessionID: String, request: AcpAgentStartRequest) async throws -> String {
    recordedEvents.append("start-agent:\(sessionID):\(request.agent):\(request.prompt ?? "")")
    return "Agent started."
  }

  func stopAgent(agentID: String) async throws -> String {
    recordedEvents.append("stop-agent:\(agentID)")
    return "Agent stopped."
  }

  func promptAgent(agentID: String, prompt: String) async throws -> String {
    recordedEvents.append("prompt-agent:\(agentID):\(prompt)")
    return "Agent prompted."
  }

  func approvePullRequest(_ target: ReviewTarget) async throws -> String {
    recordedEvents.append("approve-pr:\(target.repository)#\(target.number)")
    return "PR approved."
  }

  func labelPullRequest(_ target: ReviewTarget, label: String) async throws -> String {
    recordedEvents.append("label-pr:\(target.repository)#\(target.number):\(label)")
    return "PR labeled."
  }

  func rerunPullRequestChecks(_ target: ReviewTarget) async throws -> String {
    recordedEvents.append("rerun-pr:\(target.repository)#\(target.number)")
    return "Checks rerun."
  }

  func mergePullRequest(
    _ target: ReviewTarget,
    method: TaskBoardGitHubMergeMethod
  ) async throws -> String {
    recordedEvents.append(
      "merge-pr:\(target.repository)#\(target.number):\(method.rawValue):\(target.headSha)"
    )
    return "PR merged."
  }

  func refresh(scope: MobileRelayRefreshScope, target: ReviewTarget?) async throws -> String {
    let targetLabel = target.map { "\($0.repository)#\($0.number)" } ?? "none"
    recordedEvents.append("refresh:\(scope.rawValue):\(targetLabel)")
    return "Refreshed."
  }
}

extension AcpPermissionDecision {
  fileprivate var eventValue: String {
    switch self {
    case .approveAll:
      "approveAll"
    case .approveSome(let requestIDs):
      "approveSome:\(requestIDs.joined(separator: ","))"
    case .denyAll:
      "denyAll"
    }
  }
}
