import Foundation
import HarnessMonitorCore
import HarnessMonitorCrypto
import HarnessMonitorMirrorStore

final class RemoteDaemonCommandURLProtocol: URLProtocol, @unchecked Sendable {
  private struct StubResponse {
    let statusCode: Int
    let body: Data
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var queuedResponses: [StubResponse] = []
  nonisolated(unsafe) private static var recordedRequests: [URLRequest] = []

  static var requests: [URLRequest] {
    lock.withLock { recordedRequests }
  }

  static func reset() {
    lock.withLock {
      queuedResponses = []
      recordedRequests = []
    }
  }

  static func respond(statusCode: Int, body: String) {
    lock.withLock {
      queuedResponses = [StubResponse(statusCode: statusCode, body: Data(body.utf8))]
    }
  }

  static func enqueue(statusCode: Int = 200, body: String = "{}") {
    lock.withLock {
      queuedResponses.append(StubResponse(statusCode: statusCode, body: Data(body.utf8)))
    }
  }

  override static func canInit(with request: URLRequest) -> Bool { true }
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let response: StubResponse = Self.lock.withLock {
      var recordedRequest = request
      let body = request.httpBody ?? request.httpBodyStream.flatMap(Self.readBody)
      recordedRequest.httpBodyStream = nil
      recordedRequest.httpBody = body
      Self.recordedRequests.append(recordedRequest)
      guard !Self.queuedResponses.isEmpty else {
        return StubResponse(statusCode: 200, body: Data("{}".utf8))
      }
      return Self.queuedResponses.removeFirst()
    }
    guard let url = request.url,
      let httpResponse = HTTPURLResponse(
        url: url,
        statusCode: response.statusCode,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: response.body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  private static func readBody(_ stream: InputStream) -> Data? {
    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      guard count >= 0 else { return nil }
      guard count > 0 else { break }
      result.append(buffer, count: count)
    }
    return result
  }
}

func makeRemoteDaemonCommandClient(
  role: MobileRemoteDaemonRole = .operator,
  scopes: [String] = ["read", "write"]
) throws -> MobileRemoteDaemonSyncClient {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [RemoteDaemonCommandURLProtocol.self]
  return MobileRemoteDaemonSyncClient(
    access: try makeRemoteDaemonCommandAccess(role: role, scopes: scopes),
    stationID: "station-1",
    stationName: "daemon.example.com",
    defaultStation: true,
    session: URLSession(configuration: configuration)
  )
}

func makeRemoteDaemonCommandAccess(
  role: MobileRemoteDaemonRole,
  scopes: [String]
) throws -> MobileRemoteDaemonAccess {
  MobileRemoteDaemonAccess(
    endpoint: URL(string: "https://daemon.example.com")!,
    clientID: "ios-device",
    displayName: "Phone",
    platform: "ios",
    role: role,
    scopes: scopes,
    bearerToken: "server-token",
    tokenHint: "abcd1234",
    serverSPKISHA256: try MobileRemoteDaemonSPKIPin(
      validating: "sha256/CQ8Rnn313xPUG+5zny4xTooD6AxAsZr/anC/ea4bTIY="
    ),
    pairedAt: .now
  )
}

func makeRemoteDaemonCommand(
  kind: MobileCommandKind,
  sessionID: String? = nil,
  agentID: String? = nil,
  reviewID: String? = nil,
  taskID: String? = nil,
  payload: [String: String] = [:],
  now: Date = Date(timeIntervalSince1970: 1_752_124_400)
) -> MobileCommandRecord {
  MobileCommandRecord(
    id: "command-1",
    stationID: "station-1",
    kind: kind,
    risk: kind.risk,
    status: .draft,
    title: kind.title,
    confirmationText: "Run \(kind.title)",
    target: MobileCommandTarget(
      stationID: "station-1",
      sessionID: sessionID,
      agentID: agentID,
      reviewID: reviewID,
      taskID: taskID,
      targetRevision: 42
    ),
    payload: payload,
    actorDeviceID: "phone-identity",
    createdAt: now,
    expiresAt: now.addingTimeInterval(600),
    updatedAt: now
  )
}

func commandRequestJSON(_ request: URLRequest) throws -> [String: Any] {
  guard let body = request.httpBody else { return [:] }
  return try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
}

let remoteResolvedReviewResponse =
  #"""
  {
    "fetched_at": "2026-07-10T12:00:00Z",
    "items": [{
      "pull_request_id": "fresh-pr",
      "repository_id": "fresh-repo",
      "repository": "owner/repo",
      "number": 42,
      "title": "Fresh review",
      "url": "https://github.com/owner/repo/pull/42",
      "author_login": "octocat",
      "author_association": "member",
      "state": "open",
      "mergeable": "mergeable",
      "review_status": "approved",
      "check_status": "failure",
      "is_draft": false,
      "policy_blocked": true,
      "viewer_can_update": false,
      "viewer_can_merge_as_admin": true,
      "head_sha": "fresh-sha",
      "labels": [],
      "checks": [{
        "name": "required/ci",
        "status": "completed",
        "conclusion": "failure",
        "check_suite_id": "suite-fresh"
      }],
      "reviews": [],
      "additions": 1,
      "deletions": 1,
      "created_at": "2026-07-10T10:00:00Z",
      "updated_at": "2026-07-10T11:00:00Z",
      "required_failed_check_names": ["required/ci"],
      "has_conflict_markers": true,
      "viewer_has_active_approval": true,
      "auto_merge_enabled": false,
      "approval_requirement_satisfied_after_viewer_approval": true
    }],
    "missing_references": []
  }
  """#

actor RecordingCommandSyncClient: MobileMonitorSyncClient {
  nonisolated let supportsCommands = true
  private let disposition: MobileCommandSubmissionDisposition
  private var submissions = 0
  private var cancellations = 0

  init(disposition: MobileCommandSubmissionDisposition = .queued) {
    self.disposition = disposition
  }

  func fetchLatestSnapshot(
    stationID: String,
    now: Date
  ) async throws -> MobileMirrorSnapshot? {
    nil
  }

  func queueCommand(
    _ command: MobileCommandRecord,
    currentRevision: Int64,
    now: Date
  ) async throws -> MobileCommandSubmission {
    submissions += 1
    return MobileCommandSubmission(command: command, disposition: disposition)
  }

  func cancelCommand(
    _ command: MobileCommandRecord,
    currentRevision: Int64,
    now: Date
  ) async throws -> MobileCommandReceipt {
    cancellations += 1
    throw MobileRemoteDaemonSyncError.commandsUnavailable
  }

  func submissionCount() -> Int {
    submissions
  }

  func cancellationCount() -> Int {
    cancellations
  }
}
