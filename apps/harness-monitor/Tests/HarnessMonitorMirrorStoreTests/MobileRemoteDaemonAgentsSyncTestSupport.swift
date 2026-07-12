import Foundation
import HarnessMonitorCore
import HarnessMonitorCrypto
import HarnessMonitorMirrorStore

let agentsStationID = "remote-daemon-example-com"

func configureAgentsBaseResponses() {
  AgentsRemoteDaemonURLProtocol.respond(path: "/v1/sessions", body: agentsSessionsResponse)
  AgentsRemoteDaemonURLProtocol.respond(
    path: "/v1/task-board/items",
    body: #"{"items":[]}"#
  )
}

func makeAgentsRemoteClient(canWrite: Bool) throws -> MobileRemoteDaemonSyncClient {
  let access = MobileRemoteDaemonAccess(
    endpoint: URL(string: "https://daemon.example.com")!,
    clientID: "ios-device",
    displayName: "Phone",
    platform: "ios",
    role: canWrite ? .operator : .viewer,
    scopes: canWrite ? ["read", "write"] : ["read"],
    bearerToken: "server-token",
    tokenHint: "abcd1234",
    serverSPKISHA256: try MobileRemoteDaemonSPKIPin(
      validating: "sha256/CQ8Rnn313xPUG+5zny4xTooD6AxAsZr/anC/ea4bTIY="
    ),
    pairedAt: .now
  )
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [AgentsRemoteDaemonURLProtocol.self]
  return MobileRemoteDaemonSyncClient(
    access: access,
    stationID: agentsStationID,
    stationName: "daemon.example.com",
    defaultStation: true,
    session: URLSession(configuration: configuration)
  )
}

actor RecordingAgentsFallback: MobileMonitorSyncClient {
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

final class AgentsRemoteDaemonURLProtocol: URLProtocol, @unchecked Sendable {
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
    let response = Self.lock.withLock { () -> (Int, Data) in
      Self.capturedRequests.append(request)
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
}

let agentsSessionsResponse = """
  [
    {
      "project_name": "Harness",
      "session_id": "session-1",
      "title": "Remote session api_key=super-secret",
      "branch_ref": "main",
      "status": "active",
      "updated_at": "2026-07-10T13:00:00Z",
      "last_activity_at": "2026-07-10T13:01:00.250Z",
      "metrics": {
        "active_agent_count": 3,
        "awaiting_review_agent_count": 2
      }
    },
    {
      "project_name": "Harness",
      "session_id": "session-ended",
      "title": "Ended session",
      "branch_ref": "done",
      "status": "ended",
      "updated_at": "2026-07-09T13:00:00Z",
      "metrics": {}
    }
  ]
  """

let managedAgentsResponse = """
  {
    "agents": [
      {
        "kind": "terminal",
        "snapshot": {
          "tui_id": "terminal-1",
          "session_id": "session-1",
          "agent_id": "worker-1",
          "runtime": "codex",
          "status": "running",
          "project_dir": "/tmp/api_key=super-secret",
          "error": null,
          "updated_at": "2026-07-10T13:01:00Z"
        }
      },
      {
        "kind": "codex",
        "snapshot": {
          "run_id": "codex-1",
          "session_id": "session-1",
          "display_name": "Reviewer api_key=super-secret",
          "project_dir": "/tmp/project",
          "status": "waiting_approval",
          "prompt": "api_key=super-secret review this",
          "latest_summary": "Waiting for api_key=super-secret",
          "final_message": null,
          "error": null,
          "pending_approvals": [{ "approval_id": "approval-1" }],
          "updated_at": "2026-07-10T13:02:00Z"
        }
      },
      {
        "kind": "acp",
        "snapshot": {
          "managed_agent_id": "acp-1",
          "session_id": "session-1",
          "session_agent_id": "worker-2",
          "display_name": "ACP api_key=super-secret",
          "status": "active",
          "project_dir": "/tmp/api_key=super-secret",
          "pending_permissions": 2,
          "pending_permission_batches": [
            {
              "batch_id": "batch-1",
              "managed_agent_id": "acp-1",
              "session_id": "session-1",
              "requests": [{ "request_id": "one" }, { "request_id": "two" }],
              "created_at": "2026-07-10T13:03:00Z"
            }
          ],
          "updated_at": "2026-07-10T13:03:00Z"
        }
      }
    ]
  }
  """
