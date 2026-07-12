import Foundation
import HarnessMonitorCore
import HarnessMonitorCrypto
import HarnessMonitorMirrorStore
import XCTest

final class MobileRemoteDaemonReviewsSyncTests: XCTestCase {
  override func setUp() {
    super.setUp()
    ReviewsRemoteDaemonURLProtocol.reset()
  }

  override func tearDown() {
    ReviewsRemoteDaemonURLProtocol.reset()
    super.tearDown()
  }

  func testFetchPostsPairedQueryAndBuildsReviewsAndAttention() async throws {
    ReviewsRemoteDaemonURLProtocol.respond(path: "/v1/sessions", body: "[]")
    ReviewsRemoteDaemonURLProtocol.respond(path: "/v1/task-board/items", body: #"{"items":[]}"#)
    ReviewsRemoteDaemonURLProtocol.respond(path: "/v1/reviews/query", body: reviewsResponse)
    let client = MobileRemoteDaemonSyncClient(
      access: try reviewsRemoteAccess(),
      stationID: "remote-daemon-example-com",
      stationName: "daemon.example.com",
      defaultStation: true,
      session: makeReviewsSession()
    )
    let now = Date(timeIntervalSince1970: 1_752_124_400)

    let fetchedSnapshot = try await client.fetchLatestSnapshot(
      stationID: "remote-daemon-example-com",
      now: now
    )
    let snapshot = try XCTUnwrap(fetchedSnapshot)

    let request = try XCTUnwrap(
      ReviewsRemoteDaemonURLProtocol.requests.first { $0.url?.path == "/v1/reviews/query" }
    )
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer server-token")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "x-harness-remote-client-id"),
      "ios-device"
    )
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    let body = try XCTUnwrap(request.httpBody)
    let query = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(query["organizations"] as? [String], ["smykla-skalski"])
    XCTAssertEqual(query["repositories"] as? [String], ["smykla-skalski/harness"])
    XCTAssertEqual(query["cache_max_age_seconds"] as? Int, 45)
    XCTAssertEqual(query["force_refresh"] as? Bool, false)

    let review = try XCTUnwrap(snapshot.reviews.first)
    XCTAssertEqual(review.id, "pr-232")
    XCTAssertEqual(review.stationID, "remote-daemon-example-com")
    XCTAssertEqual(review.repository, "smykla-skalski/harness")
    XCTAssertEqual(review.number, 232)
    XCTAssertEqual(review.title, "Fix api_key=[redacted]")
    XCTAssertEqual(review.author, "bart api_key=[redacted]")
    XCTAssertEqual(review.reviewStatus, "review_required")
    XCTAssertEqual(review.checkStatus, "failure")
    XCTAssertEqual(review.checks.first?.name, "CI api_key=[redacted]")
    XCTAssertEqual(review.requiredFailedCheckNames, ["CI"])
    XCTAssertTrue(review.needsYou)
    let attention = try XCTUnwrap(snapshot.attention.first)
    XCTAssertEqual(attention.id, "review-pr-232")
    XCTAssertEqual(attention.kind, .pullRequest)
    XCTAssertEqual(attention.severity, .critical)
    XCTAssertEqual(attention.commandKind, .pullRequestRerunChecks)
    XCTAssertEqual(attention.target?.reviewID, "pr-232")
    XCTAssertEqual(attention.commandPayload["repository"], "smykla-skalski/harness")
    XCTAssertEqual(attention.commandPayload["number"], "232")
    XCTAssertEqual(snapshot.stations.first?.needsYouCount, 1)
    XCTAssertEqual(snapshot.needsYouCount, 1)
  }

  func testReviewsUnauthorizedFailsClosedWithoutCloudFallback() async throws {
    ReviewsRemoteDaemonURLProtocol.respond(path: "/v1/sessions", body: "[]")
    ReviewsRemoteDaemonURLProtocol.respond(path: "/v1/task-board/items", body: #"{"items":[]}"#)
    ReviewsRemoteDaemonURLProtocol.respond(
      path: "/v1/reviews/query",
      statusCode: 401,
      body: #"{"error":"unauthorized"}"#
    )
    let direct = MobileRemoteDaemonSyncClient(
      access: try reviewsRemoteAccess(),
      stationID: "remote-daemon-example-com",
      stationName: "daemon.example.com",
      defaultStation: true,
      session: makeReviewsSession()
    )
    let fallback = RecordingReviewsFallback()
    let client = DirectFirstMobileMonitorSyncClient(direct: direct, cloudFallback: fallback)

    do {
      _ = try await client.fetchLatestSnapshot(
        stationID: "remote-daemon-example-com",
        now: .now
      )
      XCTFail("expected unauthorized response")
    } catch let error as MobileRemoteDaemonSyncError {
      XCTAssertEqual(error, .unauthorized)
    }

    let fallbackFetchCount = await fallback.fetchCount()
    XCTAssertEqual(fallbackFetchCount, 0)
  }

  func testReadOnlyReviewAttentionDoesNotExposeCommand() async throws {
    var response = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(reviewsResponse.utf8)) as? [String: Any]
    )
    var items = try XCTUnwrap(response["items"] as? [[String: Any]])
    items[0]["viewer_can_update"] = false
    response["items"] = items
    let responseData = try JSONSerialization.data(withJSONObject: response)
    ReviewsRemoteDaemonURLProtocol.respond(path: "/v1/sessions", body: "[]")
    ReviewsRemoteDaemonURLProtocol.respond(path: "/v1/task-board/items", body: #"{"items":[]}"#)
    ReviewsRemoteDaemonURLProtocol.respond(
      path: "/v1/reviews/query",
      body: String(decoding: responseData, as: UTF8.self)
    )
    let client = MobileRemoteDaemonSyncClient(
      access: try reviewsRemoteAccess(),
      stationID: "remote-daemon-example-com",
      stationName: "daemon.example.com",
      defaultStation: true,
      session: makeReviewsSession()
    )

    let fetchedSnapshot = try await client.fetchLatestSnapshot(
      stationID: "remote-daemon-example-com",
      now: .now
    )
    let attention = try XCTUnwrap(fetchedSnapshot?.attention.first)

    XCTAssertNil(attention.commandKind)
    XCTAssertNil(attention.target)
    XCTAssertTrue(attention.commandPayload.isEmpty)
  }

  func testReadOnlyRemoteProfileDoesNotExposeReviewCommand() async throws {
    ReviewsRemoteDaemonURLProtocol.respond(path: "/v1/sessions", body: "[]")
    ReviewsRemoteDaemonURLProtocol.respond(path: "/v1/task-board/items", body: #"{"items":[]}"#)
    ReviewsRemoteDaemonURLProtocol.respond(path: "/v1/reviews/query", body: reviewsResponse)
    var access = try reviewsRemoteAccess()
    access.role = .viewer
    access.scopes = ["read"]
    let client = MobileRemoteDaemonSyncClient(
      access: access,
      stationID: "remote-daemon-example-com",
      stationName: "daemon.example.com",
      defaultStation: true,
      session: makeReviewsSession()
    )

    let fetchedSnapshot = try await client.fetchLatestSnapshot(
      stationID: "remote-daemon-example-com",
      now: .now
    )
    let attention = try XCTUnwrap(fetchedSnapshot?.attention.first)

    XCTAssertNil(attention.commandKind)
    XCTAssertNil(attention.target)
    XCTAssertTrue(attention.commandPayload.isEmpty)
  }

  func testReviewsServerFailureUsesCloudFallback() async throws {
    ReviewsRemoteDaemonURLProtocol.respond(path: "/v1/sessions", body: "[]")
    ReviewsRemoteDaemonURLProtocol.respond(path: "/v1/task-board/items", body: #"{"items":[]}"#)
    ReviewsRemoteDaemonURLProtocol.respond(
      path: "/v1/reviews/query",
      statusCode: 503,
      body: #"{"error":"unavailable"}"#
    )
    let direct = MobileRemoteDaemonSyncClient(
      access: try reviewsRemoteAccess(),
      stationID: "remote-daemon-example-com",
      stationName: "daemon.example.com",
      defaultStation: true,
      session: makeReviewsSession()
    )
    let fallback = RecordingReviewsFallback()
    let client = DirectFirstMobileMonitorSyncClient(direct: direct, cloudFallback: fallback)

    let snapshot = try await client.fetchLatestSnapshot(
      stationID: "remote-daemon-example-com",
      now: .now
    )

    XCTAssertNotNil(snapshot)
    let fallbackFetchCount = await fallback.fetchCount()
    XCTAssertEqual(fallbackFetchCount, 1)
  }
}

private actor RecordingReviewsFallback: MobileMonitorSyncClient {
  private var fetches = 0

  func fetchLatestSnapshot(stationID: String, now: Date) async throws -> MobileMirrorSnapshot? {
    fetches += 1
    return .empty(now: now)
  }

  func queueCommand(
    _ command: MobileCommandRecord,
    currentRevision: Int64,
    now: Date
  ) async throws -> MobileCommandSubmission {
    MobileCommandSubmission(command: command)
  }

  func cancelCommand(
    _ command: MobileCommandRecord,
    currentRevision: Int64,
    now: Date
  ) async throws -> MobileCommandReceipt {
    throw MobileRemoteDaemonSyncError.commandsUnavailable
  }

  func fetchCount() -> Int { fetches }
}

private final class ReviewsRemoteDaemonURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var responses: [String: (Int, Data)] = [:]
  nonisolated(unsafe) private static var capturedRequests: [URLRequest] = []

  static var requests: [URLRequest] {
    lock.withLock { capturedRequests }
  }

  static func reset() {
    lock.withLock {
      responses = [:]
      capturedRequests = []
    }
  }

  static func respond(path: String, statusCode: Int = 200, body: String) {
    lock.withLock {
      responses[path] = (statusCode, Data(body.utf8))
    }
  }

  override static func canInit(with request: URLRequest) -> Bool { true }
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    var capturedRequest = request
    capturedRequest.httpBody = request.httpBody ?? request.httpBodyStream.flatMap(Self.readBodyStream)
    let response = Self.lock.withLock { () -> (Int, Data) in
      Self.capturedRequests.append(capturedRequest)
      return Self.responses[request.url?.path ?? ""] ?? (404, Data())
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

  private static func readBodyStream(_ stream: InputStream) -> Data? {
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      guard count >= 0 else { return nil }
      if count == 0 { break }
      data.append(buffer, count: count)
    }
    return data
  }
}

private func makeReviewsSession() -> URLSession {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [ReviewsRemoteDaemonURLProtocol.self]
  return URLSession(configuration: configuration)
}

private func reviewsRemoteAccess() throws -> MobileRemoteDaemonAccess {
  MobileRemoteDaemonAccess(
    endpoint: URL(string: "https://daemon.example.com")!,
    clientID: "ios-device",
    displayName: "Phone",
    platform: "ios",
    role: .operator,
    scopes: ["read", "write"],
    bearerToken: "server-token",
    tokenHint: "abcd1234",
    serverSPKISHA256: try MobileRemoteDaemonSPKIPin(
      validating: "sha256/CQ8Rnn313xPUG+5zny4xTooD6AxAsZr/anC/ea4bTIY="
    ),
    pairedAt: .now,
    reviewsQuery: MobileRemoteDaemonReviewsQuery(
      organizations: ["smykla-skalski"],
      repositories: ["smykla-skalski/harness"],
      cacheMaxAgeSeconds: 45
    )
  )
}

private let reviewsResponse = """
  {
    "fetched_at": "2026-07-12T18:00:00Z",
    "from_cache": false,
    "summary": {
      "total": 1,
      "review_required": 1,
      "ready_to_merge": 0,
      "auto_approvable": 0,
      "waiting_on_checks": 0,
      "blocked": 1
    },
    "items": [
      {
        "pull_request_id": "pr-232",
        "repository_id": "R_harness",
        "repository": "smykla-skalski/harness",
        "number": 232,
        "title": "Fix api_key=super-secret",
        "url": "https://github.com/smykla-skalski/harness/pull/232",
        "author_login": "bart api_key=super-secret",
        "state": "open",
        "mergeable": "mergeable",
        "review_status": "review_required",
        "check_status": "failure",
        "is_draft": false,
        "policy_blocked": false,
        "viewer_can_update": true,
        "viewer_is_requested_reviewer": true,
        "viewer_can_merge_as_admin": true,
        "head_sha": "abc123",
        "labels": ["bug"],
        "checks": [
          {
            "name": "CI api_key=super-secret",
            "status": "completed",
            "conclusion": "failure",
            "check_suite_id": "42",
            "details_url": "https://ci.example.com/run/42"
          }
        ],
        "reviews": [],
        "additions": 12,
        "deletions": 4,
        "created_at": "2026-07-12T17:00:00Z",
        "updated_at": "2026-07-12T18:01:00.250Z",
        "required_failed_check_names": ["CI"]
      }
    ]
  }
  """
