import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto
import HarnessMonitorKit
import HarnessMonitorMacRelay
import XCTest

actor MobileRelayPairingCommandTrustStore: MobilePairingTrustedDeviceStore,
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

struct FixedSnapshotSource: MobileMirrorSnapshotSource {
  let snapshot: MobileMirrorSnapshot

  func makeSnapshot(now: Date) async throws -> MobileMirrorSnapshot {
    snapshot
  }
}

actor RecordingMobileMirrorSnapshotSink: MobileMirrorSnapshotSink {
  private var recordedSnapshots: [MobileMirrorSnapshot] = []

  func writeSnapshot(_ snapshot: MobileMirrorSnapshot) async throws {
    recordedSnapshots.append(snapshot)
  }

  func snapshots() -> [MobileMirrorSnapshot] {
    recordedSnapshots
  }
}

struct SecretSucceedingMobileRelayCommandExecutor: MobileRelayCommandExecutor {
  var message: String

  func execute(
    _ command: MobileCommandRecord,
    snapshot: MobileMirrorSnapshot
  ) async throws -> MobileCommandReceipt {
    MobileCommandReceipt(
      commandID: command.id,
      stationID: command.stationID,
      status: .succeeded,
      message: message,
      receivedAt: snapshot.generatedAt,
      completedAt: snapshot.generatedAt,
      executionRevision: snapshot.revision
    )
  }
}

struct SecretFailingMobileRelayCommandExecutor: MobileRelayCommandExecutor {
  var message: String

  func execute(
    _: MobileCommandRecord,
    snapshot _: MobileMirrorSnapshot
  ) async throws -> MobileCommandReceipt {
    throw MobileRelayTransientTestError(message: message)
  }
}

struct MissingCloudKitSchemaSnapshotSink: MobileMirrorSnapshotSink {
  func writeSnapshot(_: MobileMirrorSnapshot) async throws {
    throw MobileCloudMirrorCloudKitError.schemaUnavailable(
      MobileCloudMirrorCloudKitSchema.recordType
    )
  }
}

actor MobileMirrorClientProviderBox {
  private var storedClient: (any MobileMirrorClient)?

  init(client: any MobileMirrorClient) {
    self.storedClient = client
  }

  func client() -> (any MobileMirrorClient)? {
    storedClient
  }

  func setClient(_ client: (any MobileMirrorClient)?) {
    storedClient = client
  }
}

actor MobileRelayFailureHandlerProbe {
  private var reasons: [String] = []

  func record(_ reason: String) {
    reasons.append(reason)
  }

  func recordedReasons() -> [String] {
    reasons
  }
}

struct MobileRelayTransientTestError: Error, LocalizedError, Sendable {
  var message: String

  var errorDescription: String? {
    message
  }
}

struct FixedMobileMirrorClient: MobileMirrorClient {
  let health: HealthResponse
  let sessions: [SessionSummary]
  let agents: [String: [ManagedAgentSnapshot]]
  var details: [String: SessionDetail] = [:]
  let reviews: [ReviewItem]
  var reviewFiles: [String: ReviewsFilesListResponse] = [:]
  var reviewTimelines: [String: ReviewsTimelineResponse] = [:]
  var taskBoardItemsFixture: [TaskBoardItem] = []
  var reviewQueryRecorder: ReviewQueryRecorder?
  var reviewDetailRecorder: ReviewDetailRecorder?
  var healthError: (any Error & Sendable)?
  var healthUnavailable = false
  var reviewsUnavailable = false
  var taskBoardUnavailable = false
  var unavailableManagedAgentSessionIDs: Set<String> = []
  var unavailableSessionDetailIDs: Set<String> = []

  func health() async throws -> HealthResponse {
    if let healthError {
      throw healthError
    }
    if healthUnavailable {
      throw HarnessMonitorAPIError.server(code: 503, message: "Health unavailable")
    }
    return health
  }

  func sessions() async throws -> [SessionSummary] {
    sessions
  }

  func managedAgents(sessionID: String) async throws -> ManagedAgentListResponse {
    if unavailableManagedAgentSessionIDs.contains(sessionID) {
      throw HarnessMonitorAPIError.server(code: 503, message: "Managed agents unavailable")
    }
    return ManagedAgentListResponse(agents: agents[sessionID] ?? [])
  }

  func sessionDetail(id: String, scope: String?) async throws -> SessionDetail {
    if unavailableSessionDetailIDs.contains(id) {
      throw HarnessMonitorAPIError.server(code: 503, message: "Session detail unavailable")
    }
    if let detail = details[id] {
      return detail
    }
    return SessionDetail(
      session: sessions.first { $0.sessionId == id }
        ?? SessionSummary(
          projectId: "missing",
          projectName: "Missing",
          sessionId: id,
          context: "",
          status: .ended,
          createdAt: "2023-11-14T22:00:00Z",
          updatedAt: "2023-11-14T22:00:00Z",
          lastActivityAt: nil,
          leaderId: nil,
          observeId: nil,
          pendingLeaderTransfer: nil,
          metrics: SessionMetrics()
        ),
      agents: [],
      tasks: [],
      signals: [],
      observer: nil,
      agentActivity: []
    )
  }

  func queryReviews(request: ReviewsQueryRequest) async throws -> ReviewsQueryResponse {
    await reviewQueryRecorder?.record(request)
    if reviewsUnavailable {
      throw HarnessMonitorAPIError.server(code: 503, message: "Reviews unavailable")
    }
    return ReviewsQueryResponse(
      fetchedAt: "2023-11-14T22:05:00Z",
      fromCache: false,
      summary: ReviewsSummary(items: reviews),
      items: reviews
    )
  }

  func listReviewFiles(request: ReviewsFilesListRequest) async throws -> ReviewsFilesListResponse {
    await reviewDetailRecorder?.recordFileRequest(request.pullRequestID)
    guard let response = reviewFiles[request.pullRequestID] else {
      throw HarnessMonitorAPIError.server(code: 404, message: "Review files unavailable")
    }
    return response
  }

  func fetchReviewTimeline(
    request: ReviewsTimelineRequest
  ) async throws -> ReviewsTimelineResponse {
    await reviewDetailRecorder?.recordTimelineRequest(request.pullRequestId)
    guard let response = reviewTimelines[request.pullRequestId] else {
      throw HarnessMonitorAPIError.server(code: 404, message: "Review timeline unavailable")
    }
    return response
  }

  func taskBoardItems(status: TaskBoardStatus?) async throws -> [TaskBoardItem] {
    if taskBoardUnavailable {
      throw HarnessMonitorAPIError.server(code: 503, message: "Task board unavailable")
    }
    guard let status else {
      return taskBoardItemsFixture
    }
    return taskBoardItemsFixture.filter { $0.status == status }
  }
}

actor PairAcceptedProbe {
  private(set) var count = 0

  func record() {
    count += 1
  }
}
