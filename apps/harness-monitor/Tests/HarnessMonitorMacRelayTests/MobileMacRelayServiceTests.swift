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

  func testStationIdentityStorePersistsStationKeys() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileURL = directory.appendingPathComponent("station-identity.json")
    let store = MobileMacStationIdentityStore(fileURL: fileURL)

    let first = try store.loadOrCreate(
      stationName: "Studio",
      now: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let second = try store.loadOrCreate(
      stationName: "Studio Renamed",
      now: Date(timeIntervalSince1970: 1_700_001_000)
    )

    XCTAssertEqual(second.stationID, first.stationID)
    XCTAssertEqual(
      second.agreementPrivateKeyRawRepresentation, first.agreementPrivateKeyRawRepresentation)
    XCTAssertEqual(second.stationName, "Studio Renamed")
  }

  func testClientSnapshotSourceMirrorsLiveStateAndCommandPayloads() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let session = SessionSummary(
      projectId: "project",
      projectName: "Harness",
      sessionId: "session-1",
      branchRef: "main",
      title: "Mobile relay",
      context: "Shipping the mobile relay.",
      status: .active,
      createdAt: "2023-11-14T22:00:00Z",
      updatedAt: "2023-11-14T22:01:00Z",
      lastActivityAt: "2023-11-14T22:02:00Z",
      leaderId: nil,
      observeId: nil,
      pendingLeaderTransfer: nil,
      metrics: SessionMetrics(activeAgentCount: 1)
    )
    let acpAgent = ManagedAgentSnapshot.acp(
      AcpAgentSnapshot(
        acpId: "acp-1",
        sessionId: session.sessionId,
        agentId: "agent-1",
        displayName: "Codex",
        status: .active,
        pid: 123,
        pgid: 123,
        projectDir: "/repo",
        pendingPermissions: 1,
        permissionQueueDepth: 1,
        pendingPermissionBatches: [
          AcpPermissionBatch(
            batchId: "batch-1",
            acpId: "acp-1",
            sessionId: session.sessionId,
            requests: [],
            createdAt: "2023-11-14T22:03:00Z"
          )
        ],
        terminalCount: 0,
        createdAt: "2023-11-14T22:00:00Z",
        updatedAt: "2023-11-14T22:03:00Z"
      )
    )
    let review = ReviewItem(
      pullRequestID: "review-1",
      repositoryID: "repo-1",
      repository: "smykla-skalski/harness",
      number: 812,
      title: "Add mobile relay",
      url: "https://github.com/smykla-skalski/harness/pull/812",
      authorLogin: "codex",
      state: .open,
      mergeable: .mergeable,
      reviewStatus: .reviewRequired,
      checkStatus: .success,
      policyBlocked: false,
      isDraft: false,
      headSha: "abc123",
      additions: 10,
      deletions: 1,
      createdAt: "2023-11-14T22:00:00Z",
      updatedAt: "2023-11-14T22:04:00Z"
    )
    let source = HarnessMonitorClientMobileMirrorSnapshotSource(
      stationID: "station",
      stationName: "Studio",
      clientProvider: {
        FixedMobileMirrorClient(
          health: HealthResponse(
            status: "ok",
            version: "1.0.0",
            pid: 1,
            endpoint: "http://127.0.0.1:1",
            startedAt: "2023-11-14T22:00:00Z",
            projectCount: 1,
            sessionCount: 1
          ),
          sessions: [session],
          agents: [session.sessionId: [acpAgent]],
          reviews: [review]
        )
      },
      trustedDeviceProvider: {
        [
          MobileDeviceDescriptor(
            id: "device-phone",
            displayName: "Phone",
            publicKeyFingerprint: "AA:BB",
            pairedAt: now
          )
        ]
      }
    )

    let snapshot = try await source.makeSnapshot(now: now)
    let permission: MobileAttentionItem = try XCTUnwrap(
      snapshot.attention.first { $0.kind == MobileAttentionKind.acpDecision }
    )
    let reviewAttention: MobileAttentionItem = try XCTUnwrap(
      snapshot.attention.first { $0.kind == MobileAttentionKind.pullRequest }
    )

    XCTAssertEqual(snapshot.stations.first?.state, .online)
    XCTAssertEqual(snapshot.sessions.first?.activeAgentCount, 1)
    XCTAssertEqual(permission.commandPayload["batchID"], "batch-1")
    XCTAssertEqual(permission.commandPayload["decision"], "approve_all")
    XCTAssertEqual(reviewAttention.commandPayload["repository"], "smykla-skalski/harness")
    XCTAssertEqual(snapshot.trustedDevices.first?.id, "device-phone")
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

private actor MobileRelayPairingCommandTrustStore: MobilePairingTrustedDeviceStore,
  MobileCommandTrustStore
{
  private let devices: [MobilePairingTrustedDevice]

  init(devices: [MobilePairingTrustedDevice]) {
    self.devices = devices
  }

  func trust(_ device: MobilePairingTrustedDevice) async throws {
    _ = device
  }

  func trustedDevice(
    deviceID: String,
    signingKeyFingerprint: String
  ) async throws -> MobilePairingTrustedDevice? {
    devices.first { $0.deviceID == deviceID && $0.signingKeyFingerprint == signingKeyFingerprint }
  }

  func trustedDevices() async throws -> [MobilePairingTrustedDevice] {
    devices
  }

  func publicSigningKey(
    actorDeviceID: String,
    signingKeyFingerprint: String
  ) async throws -> Data? {
    devices
      .first { $0.deviceID == actorDeviceID && $0.signingKeyFingerprint == signingKeyFingerprint }?
      .signingPublicKeyRawRepresentation
  }
}

private struct FixedSnapshotSource: MobileMirrorSnapshotSource {
  let snapshot: MobileMirrorSnapshot

  func makeSnapshot(now: Date) async throws -> MobileMirrorSnapshot {
    snapshot
  }
}

private struct FixedMobileMirrorClient: MobileMirrorClient {
  let health: HealthResponse
  let sessions: [SessionSummary]
  let agents: [String: [ManagedAgentSnapshot]]
  let reviews: [ReviewItem]

  func health() async throws -> HealthResponse {
    health
  }

  func sessions() async throws -> [SessionSummary] {
    sessions
  }

  func managedAgents(sessionID: String) async throws -> ManagedAgentListResponse {
    ManagedAgentListResponse(agents: agents[sessionID] ?? [])
  }

  func queryReviews(request: ReviewsQueryRequest) async throws -> ReviewsQueryResponse {
    ReviewsQueryResponse(
      fetchedAt: "2023-11-14T22:05:00Z",
      fromCache: false,
      summary: ReviewsSummary(items: reviews),
      items: reviews
    )
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
