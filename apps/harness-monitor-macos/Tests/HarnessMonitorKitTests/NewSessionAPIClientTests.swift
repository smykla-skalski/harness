import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("New session API client")
struct NewSessionAPIClientTests {
  @Test("startSession posts to /v1/sessions and decodes the state wrapper")
  func startSessionPostsAndDecodesStateWrapper() async throws {
    StartSessionURLProtocol.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StartSessionURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let client = HarnessMonitorAPIClient(
      connection: HarnessMonitorConnection(
        endpoint: URL(string: "http://127.0.0.1:9999")!,
        token: "token"
      ),
      session: session
    )

    let request = SessionStartRequest(
      title: "test session",
      context: "unit test context",
      runtime: "claude",
      sessionId: nil,
      projectDir: "bmk-abc",
      policyPreset: nil,
      baseRef: "main"
    )

    let summary = try await client.startSession(request: request)

    #expect(summary.sessionId == "sess-new-1")
    #expect(StartSessionURLProtocol.lastRequestPath == "/v1/sessions")
    #expect(StartSessionURLProtocol.lastRequestMethod == "POST")
  }
}

private final class StartSessionURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var requestPath: String?
  nonisolated(unsafe) private static var requestMethod: String?

  static var lastRequestPath: String? {
    lock.withLock { requestPath }
  }

  static var lastRequestMethod: String? {
    lock.withLock { requestMethod }
  }

  static func reset() {
    lock.withLock {
      requestPath = nil
      requestMethod = nil
    }
  }

  override static func canInit(with request: URLRequest) -> Bool {
    true
  }

  override static func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }

    Self.lock.withLock {
      Self.requestPath = url.path
      Self.requestMethod = request.httpMethod
    }

    guard
      let response = HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }

    let responseBody =
      """
      {
        "state": {
          "project_id": "project-6ccf8d0a",
          "project_name": "harness",
          "project_dir": "/Users/example/Projects/harness",
          "context_root": "/Users/example/Library/Application Support/harness/sessions/harness",
          "session_id": "sess-new-1",
          "worktree_path": "",
          "shared_path": "",
          "origin_path": "",
          "branch_ref": "main",
          "title": "test session",
          "context": "unit test context",
          "status": "active",
          "created_at": "2026-04-20T12:00:00Z",
          "updated_at": "2026-04-20T12:00:00Z",
          "last_activity_at": null,
          "leader_id": null,
          "observe_id": null,
          "pending_leader_transfer": null,
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

    let data = Data(responseBody.utf8)
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
