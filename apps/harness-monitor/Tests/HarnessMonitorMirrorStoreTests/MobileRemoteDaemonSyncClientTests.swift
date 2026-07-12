import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto
import HarnessMonitorMirrorStore
import XCTest

final class MobileRemoteDaemonSyncClientTests: XCTestCase {
  override func setUp() {
    super.setUp()
    RemoteDaemonSessionsURLProtocol.reset()
  }

  override func tearDown() {
    RemoteDaemonSessionsURLProtocol.reset()
    super.tearDown()
  }

  func testFetchBuildsAuthenticatedRemoteSessionsSnapshot() async throws {
    RemoteDaemonSessionsURLProtocol.respond(statusCode: 200, body: sessionsResponse)
    let client = MobileRemoteDaemonSyncClient(
      access: try remoteAccess(),
      stationID: "remote-daemon-example-com",
      stationName: "daemon.example.com",
      defaultStation: false,
      session: makeSession()
    )
    let now = Date(timeIntervalSince1970: 1_752_124_400)

    let fetchedSnapshot = try await client.fetchLatestSnapshot(
      stationID: "remote-daemon-example-com",
      now: now
    )
    let snapshot = try XCTUnwrap(fetchedSnapshot)

    let request = try XCTUnwrap(
      RemoteDaemonSessionsURLProtocol.requests.first { $0.url?.path == "/v1/sessions" }
    )
    XCTAssertEqual(request.url?.absoluteString, "https://daemon.example.com/v1/sessions")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer server-token")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "x-harness-remote-client-id"),
      "ios-device"
    )
    XCTAssertEqual(snapshot.generatedAt, now)
    XCTAssertEqual(snapshot.expiresAt, now.addingTimeInterval(60))
    XCTAssertEqual(snapshot.revision, 0)
    XCTAssertEqual(snapshot.stations.first?.state, .online)
    XCTAssertEqual(snapshot.stations.first?.activeSessionCount, 1)
    XCTAssertEqual(snapshot.stations.first?.defaultStation, false)
    XCTAssertEqual(snapshot.sessions.first?.id, "session-1")
    XCTAssertEqual(snapshot.sessions.first?.title, "Remote work api_key=[redacted]")
    XCTAssertEqual(snapshot.sessions.first?.status, "Active")
    XCTAssertEqual(snapshot.sessions.first?.activeAgentCount, 2)
    XCTAssertEqual(snapshot.sessions.first?.blockedAgentCount, 1)
    let expectedActivity = try Date.ISO8601FormatStyle().year().month().day()
      .timeZone(separator: .omitted)
      .time(includingFractionalSeconds: true)
      .parse("2026-07-10T13:01:00.250Z")
    XCTAssertEqual(snapshot.sessions.first?.lastActivityAt, expectedActivity)
    XCTAssertFalse(snapshot.sessions.first?.summary.contains("super-secret") ?? true)
    XCTAssertFalse(client.supportsCommands)
  }

  func testFetchIncludesAuthenticatedRemoteTaskBoardSnapshot() async throws {
    RemoteDaemonSessionsURLProtocol.respond(
      path: "/v1/sessions",
      statusCode: 200,
      body: sessionsResponse
    )
    RemoteDaemonSessionsURLProtocol.respond(
      path: "/v1/task-board/items",
      statusCode: 200,
      body: taskBoardResponse
    )
    let client = MobileRemoteDaemonSyncClient(
      access: try remoteAccess(),
      stationID: "remote-daemon-example-com",
      stationName: "daemon.example.com",
      defaultStation: false,
      session: makeSession()
    )
    let now = Date(timeIntervalSince1970: 1_752_124_400)

    let fetchedSnapshot = try await client.fetchLatestSnapshot(
      stationID: "remote-daemon-example-com",
      now: now
    )
    let snapshot = try XCTUnwrap(fetchedSnapshot)

    let requests = RemoteDaemonSessionsURLProtocol.requests
    XCTAssertEqual(Set(requests.compactMap(\.url?.path)), [
      "/v1/sessions", "/v1/task-board/items",
    ])
    for request in requests {
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer server-token")
      XCTAssertEqual(
        request.value(forHTTPHeaderField: "x-harness-remote-client-id"),
        "ios-device"
      )
    }
    let item = try XCTUnwrap(snapshot.taskBoardItems.first)
    XCTAssertEqual(item.id, "board-1")
    XCTAssertEqual(item.stationID, "remote-daemon-example-com")
    XCTAssertEqual(item.title, "Approve deployment")
    XCTAssertEqual(
      item.bodyPreview,
      "Review the production rollout plan api_key=[redacted]"
    )
    XCTAssertEqual(item.status, "human_required")
    XCTAssertEqual(item.statusTitle, "Human Required")
    XCTAssertEqual(item.priority, "high")
    XCTAssertEqual(item.priorityTitle, "High")
    XCTAssertEqual(item.tags, [])
    XCTAssertEqual(item.projectID, "harness")
    XCTAssertEqual(item.sessionID, "session-1")
    XCTAssertEqual(item.workItemID, "work-1")
    XCTAssertEqual(item.agentMode, "headless")
    XCTAssertTrue(item.needsYou)
  }

  func testUnauthorizedDirectResponseDoesNotUseCloudFallback() async throws {
    let fallback = RecordingSyncClient(snapshot: snapshotFixture())
    let client = DirectFirstMobileMonitorSyncClient(
      direct: ThrowingSyncClient(error: MobileRemoteDaemonSyncError.unauthorized),
      cloudFallback: fallback
    )

    do {
      _ = try await client.fetchLatestSnapshot(stationID: "station-1", now: .now)
      XCTFail("expected unauthorized error")
    } catch let error as MobileRemoteDaemonSyncError {
      XCTAssertEqual(error, .unauthorized)
    }

    let fetchCount = await fallback.fetchCount()
    XCTAssertEqual(fetchCount, 0)
  }

  func testReachabilityFailureUsesCloudFallback() async throws {
    let expected = snapshotFixture()
    let fallback = RecordingSyncClient(snapshot: expected)
    let client = DirectFirstMobileMonitorSyncClient(
      direct: ThrowingSyncClient(error: URLError(.timedOut)),
      cloudFallback: fallback
    )

    let snapshot = try await client.fetchLatestSnapshot(stationID: "station-1", now: .now)

    XCTAssertEqual(snapshot, expected)
    let fetchCount = await fallback.fetchCount()
    XCTAssertEqual(fetchCount, 1)
    XCTAssertTrue(client.supportsCommands)
  }

  func testRemoteServerFailureUsesCloudFallback() async throws {
    let expected = snapshotFixture()
    let fallback = RecordingSyncClient(snapshot: expected)
    let client = DirectFirstMobileMonitorSyncClient(
      direct: ThrowingSyncClient(error: MobileRemoteDaemonSyncError.serverStatus(503)),
      cloudFallback: fallback
    )

    let snapshot = try await client.fetchLatestSnapshot(stationID: "station-1", now: .now)

    XCTAssertEqual(snapshot, expected)
    let fetchCount = await fallback.fetchCount()
    XCTAssertEqual(fetchCount, 1)
  }

  func testForbiddenDirectResponseDoesNotUseCloudFallback() async throws {
    let fallback = RecordingSyncClient(snapshot: snapshotFixture())
    let client = DirectFirstMobileMonitorSyncClient(
      direct: ThrowingSyncClient(error: MobileRemoteDaemonSyncError.forbidden),
      cloudFallback: fallback
    )

    do {
      _ = try await client.fetchLatestSnapshot(stationID: "station-1", now: .now)
      XCTFail("expected forbidden error")
    } catch let error as MobileRemoteDaemonSyncError {
      XCTAssertEqual(error, .forbidden)
    }

    let fetchCount = await fallback.fetchCount()
    XCTAssertEqual(fetchCount, 0)
  }

  func testHybridClientUsesCloudCommandsWhenDirectWriteIsUnavailable() async throws {
    let cloud = RecordingSyncClient(snapshot: snapshotFixture())
    let client = DirectFirstMobileMonitorSyncClient(
      direct: ThrowingSyncClient(error: URLError(.timedOut)),
      cloudFallback: cloud
    )

    let submission = try await client.queueCommand(
      commandFixture(),
      currentRevision: 99,
      now: .now
    )

    XCTAssertEqual(submission.command.id, "command-1")
    let commandAttempts = await cloud.commandAttemptCount()
    XCTAssertEqual(commandAttempts, 1)
  }

  func testFactoryBuildsDirectOnlyClientForRemoteCredential() throws {
    let credential = MobilePairedStationCredential(
      stationID: "remote-daemon-example-com",
      stationName: "daemon.example.com",
      endpoint: URL(string: "https://daemon.example.com")!,
      stationPublicKeyFingerprint: testSPKIPin,
      deviceIdentityID: "default-mobile-device",
      snapshotKeyID: "",
      commandKeyID: "",
      symmetricKeyRawRepresentation: Data(),
      pairedAt: .now,
      defaultStation: true,
      remoteDaemonAccess: try remoteAccess()
    )
    let identity = MobileDeviceIdentity(
      id: "default-mobile-device",
      displayName: "Phone",
      createdAt: .now
    )

    let client = LiveMobileMonitorSyncClientFactory().makeSyncClient(
      credential: credential,
      identity: identity
    )

    XCTAssertFalse(client.supportsCommands)
  }

  private func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RemoteDaemonSessionsURLProtocol.self]
    return URLSession(configuration: configuration)
  }
}

private struct ThrowingSyncClient: MobileMonitorSyncClient {
  let error: any Error
  var supportsCommands: Bool { false }

  func fetchLatestSnapshot(stationID: String, now: Date) async throws -> MobileMirrorSnapshot? {
    throw error
  }

  func queueCommand(
    _ command: MobileCommandRecord,
    currentRevision: Int64,
    now: Date
  ) async throws -> MobileCommandSubmission {
    throw error
  }

  func cancelCommand(
    _ command: MobileCommandRecord,
    currentRevision: Int64,
    now: Date
  ) async throws -> MobileCommandReceipt {
    throw error
  }
}

private actor RecordingSyncClient: MobileMonitorSyncClient {
  nonisolated let supportsCommands = true
  private let snapshot: MobileMirrorSnapshot?
  private var fetches = 0
  private var commandAttempts = 0

  init(snapshot: MobileMirrorSnapshot?) {
    self.snapshot = snapshot
  }

  func fetchLatestSnapshot(stationID: String, now: Date) async throws -> MobileMirrorSnapshot? {
    fetches += 1
    return snapshot
  }

  func queueCommand(
    _ command: MobileCommandRecord,
    currentRevision: Int64,
    now: Date
  ) async throws -> MobileCommandSubmission {
    commandAttempts += 1
    return MobileCommandSubmission(command: command)
  }

  func cancelCommand(
    _ command: MobileCommandRecord,
    currentRevision: Int64,
    now: Date
  ) async throws -> MobileCommandReceipt {
    commandAttempts += 1
    throw MobileRemoteDaemonSyncError.commandsUnavailable
  }

  func fetchCount() -> Int {
    fetches
  }

  func commandAttemptCount() -> Int {
    commandAttempts
  }
}

private final class RemoteDaemonSessionsURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var responsesByPath: [String: (Int, Data)] = [:]
  nonisolated(unsafe) private static var recordedRequests: [URLRequest] = []

  static var requests: [URLRequest] {
    lock.withLock { recordedRequests }
  }

  static func reset() {
    lock.withLock {
      responsesByPath = [:]
      recordedRequests = []
    }
  }

  static func respond(statusCode: Int, body: String) {
    respond(path: "/v1/sessions", statusCode: statusCode, body: body)
    respond(path: "/v1/task-board/items", statusCode: 200, body: #"{"items":[]}"#)
  }

  static func respond(path: String, statusCode: Int, body: String) {
    lock.withLock {
      responsesByPath[path] = (statusCode, Data(body.utf8))
    }
  }

  override static func canInit(with request: URLRequest) -> Bool { true }
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let response: (Int, Data) = Self.lock.withLock {
      Self.recordedRequests.append(request)
      return Self.responsesByPath[request.url?.path ?? ""] ?? (404, Data())
    }
    guard let url = request.url,
      let httpResponse = HTTPURLResponse(
        url: url,
        statusCode: response.0,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: response.1)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private let testSPKIPin = "sha256/CQ8Rnn313xPUG+5zny4xTooD6AxAsZr/anC/ea4bTIY="

private let sessionsResponse = """
  [
    {
      "project_name": "Harness",
      "session_id": "session-1",
      "title": "Remote work api_key=super-secret",
      "branch_ref": "main",
      "status": "active",
      "context": "api_key=super-secret",
      "updated_at": "2026-07-10T13:00:00Z",
      "last_activity_at": "2026-07-10T13:01:00.250Z",
      "metrics": {
        "active_agent_count": 2,
        "awaiting_review_agent_count": 1
      }
    },
    {
      "project_name": "Harness",
      "session_id": "session-2",
      "title": "Finished work",
      "branch_ref": "feature/done",
      "status": "ended",
      "context": "done",
      "updated_at": "2026-07-09T13:00:00Z",
      "metrics": {}
    }
  ]
  """

private let taskBoardResponse = """
  {
    "items": [
      {
        "schema_version": 1,
        "id": "board-1",
        "title": "Approve deployment",
        "body": "Review the production rollout plan api_key=super-secret",
        "status": "human_required",
        "priority": "high",
        "project_id": "harness",
        "agent_mode": "headless",
        "session_id": "session-1",
        "work_item_id": "work-1",
        "created_at": "2026-07-10T12:00:00Z",
        "updated_at": "2026-07-10T13:02:00Z"
      }
    ]
  }
  """

private func remoteAccess() throws -> MobileRemoteDaemonAccess {
  MobileRemoteDaemonAccess(
    endpoint: URL(string: "https://daemon.example.com")!,
    clientID: "ios-device",
    displayName: "Phone",
    platform: "ios",
    role: .viewer,
    scopes: ["read"],
    bearerToken: "server-token",
    tokenHint: "abcd1234",
    serverSPKISHA256: try MobileRemoteDaemonSPKIPin(validating: testSPKIPin),
    pairedAt: .now
  )
}

private func commandFixture() -> MobileCommandRecord {
  let now = Date(timeIntervalSince1970: 1_752_124_400)
  return MobileCommandRecord(
    id: "command-1",
    stationID: "station-1",
    kind: .refresh,
    risk: .low,
    status: .draft,
    title: "Refresh",
    confirmationText: "Refresh station",
    target: MobileCommandTarget(stationID: "station-1", targetRevision: 99),
    actorDeviceID: "ios-device-fingerprint",
    createdAt: now,
    expiresAt: now.addingTimeInterval(600),
    updatedAt: now
  )
}

private func snapshotFixture() -> MobileMirrorSnapshot {
  let now = Date(timeIntervalSince1970: 1_752_124_400)
  return MobileMirrorSnapshot(
    revision: 7,
    generatedAt: now,
    expiresAt: now.addingTimeInterval(60),
    stations: [],
    attention: [],
    sessions: [],
    reviews: [],
    commands: [],
    trustedDevices: []
  )
}
