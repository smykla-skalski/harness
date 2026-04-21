import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Adopt session API client")
struct AdoptSessionClientTests {
  @Test("adoptSession returns state on 200")
  func adoptSessionReturnsState() async throws {
    AdoptSessionURLProtocol.reset()
    AdoptSessionURLProtocol.configure(status: 200, body: successBody)
    let client = makeClient()
    let summary = try await client.adoptSession(
      bookmarkID: "B-abc",
      sessionRoot: URL(fileURLWithPath: "/tmp/session")
    )
    #expect(summary.sessionId == "abc12345")
    #expect(AdoptSessionURLProtocol.lastRequestPath == "/v1/sessions/adopt")
    #expect(AdoptSessionURLProtocol.lastRequestMethod == "POST")
  }

  @Test("adoptSession maps 409 already-attached to typed error")
  func adoptSessionMapsAlreadyAttached() async throws {
    AdoptSessionURLProtocol.reset()
    AdoptSessionURLProtocol.configure(
      status: 409,
      body: #"{"error":"already-attached","session_id":"abc12345"}"#
    )
    let client = makeClient()
    do {
      _ = try await client.adoptSession(
        bookmarkID: nil,
        sessionRoot: URL(fileURLWithPath: "/x")
      )
      Issue.record("expected throw")
    } catch let error as HarnessMonitorAPIError {
      guard case .adoptAlreadyAttached(let sid) = error else {
        Issue.record("unexpected error: \(error)")
        return
      }
      #expect(sid == "abc12345")
    }
  }

  @Test("adoptSession maps 422 layout-violation to typed error")
  func adoptSessionMapsLayoutViolation() async throws {
    AdoptSessionURLProtocol.reset()
    AdoptSessionURLProtocol.configure(
      status: 422,
      body: #"{"error":"layout-violation","reason":"missing workspace/"}"#
    )
    let client = makeClient()
    do {
      _ = try await client.adoptSession(
        bookmarkID: nil,
        sessionRoot: URL(fileURLWithPath: "/x")
      )
      Issue.record("expected throw")
    } catch let error as HarnessMonitorAPIError {
      guard case .adoptLayoutViolation(let reason) = error else {
        Issue.record("unexpected error: \(error)")
        return
      }
      #expect(reason == "missing workspace/")
    }
  }

  @Test("adoptSession maps 422 origin-mismatch to typed error")
  func adoptSessionMapsOriginMismatch() async throws {
    AdoptSessionURLProtocol.reset()
    AdoptSessionURLProtocol.configure(
      status: 422,
      body: #"{"error":"origin-mismatch","expected":"/a","found":"/b"}"#
    )
    let client = makeClient()
    do {
      _ = try await client.adoptSession(
        bookmarkID: nil,
        sessionRoot: URL(fileURLWithPath: "/x")
      )
      Issue.record("expected throw")
    } catch let error as HarnessMonitorAPIError {
      guard case .adoptOriginMismatch(let expected, let found) = error else {
        Issue.record("unexpected error: \(error)")
        return
      }
      #expect(expected == "/a")
      #expect(found == "/b")
    }
  }

  @Test("adoptSession maps 422 unsupported-schema-version to typed error")
  func adoptSessionMapsUnsupportedSchemaVersion() async throws {
    AdoptSessionURLProtocol.reset()
    AdoptSessionURLProtocol.configure(
      status: 422,
      body: #"{"error":"unsupported-schema-version","found":7,"supported":9}"#
    )
    let client = makeClient()
    do {
      _ = try await client.adoptSession(
        bookmarkID: nil,
        sessionRoot: URL(fileURLWithPath: "/x")
      )
      Issue.record("expected throw")
    } catch let error as HarnessMonitorAPIError {
      guard case .adoptUnsupportedSchemaVersion(let found, let supported) = error else {
        Issue.record("unexpected error: \(error)")
        return
      }
      #expect(found == 7)
      #expect(supported == 9)
    }
  }

  @Test("adoptSession passes through unknown server errors")
  func adoptSessionPassesThroughUnknownError() async throws {
    AdoptSessionURLProtocol.reset()
    AdoptSessionURLProtocol.configure(
      status: 500,
      body: #"{"error":"internal","detail":"something went wrong"}"#
    )
    let client = makeClient()
    do {
      _ = try await client.adoptSession(
        bookmarkID: nil,
        sessionRoot: URL(fileURLWithPath: "/x")
      )
      Issue.record("expected throw")
    } catch let error as HarnessMonitorAPIError {
      guard case .server(let code, _) = error else {
        Issue.record("unexpected error: \(error)")
        return
      }
      #expect(code == 500)
    }
  }
}

private func makeClient() -> HarnessMonitorAPIClient {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [AdoptSessionURLProtocol.self]
  let session = URLSession(configuration: configuration)
  guard let endpoint = URL(string: "http://127.0.0.1:9999") else {
    preconditionFailure("expected valid test endpoint")
  }
  return HarnessMonitorAPIClient(
    connection: HarnessMonitorConnection(
      endpoint: endpoint,
      token: "token"
    ),
    session: session
  )
}

private let successBody = """
  {
    "state": {
      "project_id": "project-abc",
      "project_name": "demo",
      "project_dir": "/Users/me/src/demo",
      "context_root": "",
      "session_id": "abc12345",
      "worktree_path": "",
      "shared_path": "",
      "origin_path": "/Users/me/src/demo",
      "branch_ref": "harness/abc12345",
      "title": "t",
      "context": "c",
      "status": "active",
      "created_at": "2026-04-20T12:00:00Z",
      "updated_at": "2026-04-20T12:00:00Z",
      "last_activity_at": null,
      "leader_id": null,
      "observe_id": null,
      "pending_leader_transfer": null,
      "external_origin": null,
      "adopted_at": null,
      "metrics": {
        "agent_count": 0,
        "active_agent_count": 0,
        "open_task_count": 0,
        "in_progress_task_count": 0,
        "blocked_task_count": 0,
        "completed_task_count": 0
      }
    }
  }
  """

private final class AdoptSessionURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var requestPath: String?
  nonisolated(unsafe) private static var requestMethod: String?
  nonisolated(unsafe) private static var responseStatus: Int = 200
  nonisolated(unsafe) private static var responseBody: String = ""

  static var lastRequestPath: String? { lock.withLock { requestPath } }
  static var lastRequestMethod: String? { lock.withLock { requestMethod } }

  static func reset() {
    lock.withLock {
      requestPath = nil
      requestMethod = nil
      responseStatus = 200
      responseBody = ""
    }
  }

  static func configure(status: Int, body: String) {
    lock.withLock {
      responseStatus = status
      responseBody = body
    }
  }

  override static func canInit(with request: URLRequest) -> Bool { true }
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    let (status, body): (Int, String) = Self.lock.withLock {
      (Self.responseStatus, Self.responseBody)
    }
    Self.lock.withLock {
      Self.requestPath = url.path
      Self.requestMethod = request.httpMethod
    }
    guard
      let response = HTTPURLResponse(
        url: url,
        statusCode: status,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
