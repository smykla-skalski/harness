import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("New session API client", .serialized)
struct NewSessionAPIClientTests {
  @Test("startSession posts to /v1/sessions and decodes daemon mutation state")
  func startSessionPostsAndDecodesMutationState() async throws {
    StartSessionURLProtocol.reset()
    let client = try makeClient()

    let request = SessionStartRequest(
      title: "test session",
      context: "unit test context",
      sessionId: nil,
      projectDir: "bmk-abc",
      policyPreset: nil,
      baseRef: "main"
    )

    let result = try await client.startSession(request: request)

    #expect(result.sessionId == "sess-new-1")
    #expect(StartSessionURLProtocol.lastRequestPath == "/v1/sessions")
    #expect(StartSessionURLProtocol.lastRequestMethod == "POST")
  }

  @Test("Codex managed-agent HTTP mutations use canonical paths and request bodies")
  func codexManagedAgentHTTPMutationsUseCanonicalContract() async throws {
    StartSessionURLProtocol.reset(responseKind: .codexSnapshot)
    let client = try makeClient()

    let startRequest = CodexRunRequest(
      actor: "leader-1",
      prompt: "Investigate",
      mode: .workspaceWrite,
      role: .leader,
      fallbackRole: .worker,
      capabilities: ["fs.read", "terminal.spawn"],
      name: "Codex Worker",
      persona: "reviewer",
      resumeThreadId: "thread-old",
      taskID: "task-1",
      boardItemID: "board-item-1",
      workflowExecutionID: "workflow-1",
      model: "gpt-5.5",
      effort: "high",
      allowCustomModel: true
    )

    let started = try await client.startCodexRun(sessionID: "sess-1", request: startRequest)
    _ = try await client.steerCodexRun(
      runID: "codex-run-1",
      request: CodexSteerRequest(prompt: "Continue")
    )
    _ = try await client.interruptCodexRun(runID: "codex-run-1")
    _ = try await client.resolveCodexApproval(
      runID: "codex-run-1",
      approvalID: "approval-1",
      request: CodexApprovalDecisionRequest(decision: .acceptForSession)
    )

    let records = StartSessionURLProtocol.records
    #expect(started.runId == "codex-run-1")
    #expect(records.map(\.method) == ["POST", "POST", "POST", "POST"])
    #expect(
      records.map(\.path)
        == [
          "/v1/sessions/sess-1/managed-agents/codex",
          "/v1/managed-agents/codex-run-1/steer",
          "/v1/managed-agents/codex-run-1/interrupt",
          "/v1/managed-agents/codex-run-1/approvals/approval-1",
        ]
    )

    let startBody = try #require(records.first?.body)
    #expect(startBody["actor"] as? String == "leader-1")
    #expect(startBody["prompt"] as? String == "Investigate")
    #expect(startBody["mode"] as? String == "workspace_write")
    #expect(startBody["role"] as? String == "leader")
    #expect(startBody["fallback_role"] as? String == "worker")
    #expect(startBody["capabilities"] as? [String] == ["fs.read", "terminal.spawn"])
    #expect(startBody["name"] as? String == "Codex Worker")
    #expect(startBody["persona"] as? String == "reviewer")
    #expect(startBody["resume_thread_id"] as? String == "thread-old")
    #expect(startBody["task_id"] as? String == "task-1")
    #expect(startBody["board_item_id"] as? String == "board-item-1")
    #expect(startBody["workflow_execution_id"] as? String == "workflow-1")
    #expect(startBody["model"] as? String == "gpt-5.5")
    #expect(startBody["effort"] as? String == "high")
    #expect(startBody["allow_custom_model"] as? Bool == true)

    #expect(records[1].body?["prompt"] as? String == "Continue")
    #expect(records[1].body?["managed_agent_id"] == nil)
    #expect(records[2].body?.isEmpty == true)
    #expect(records[3].body?["decision"] as? String == "accept_for_session")
    #expect(records[3].body?["approval_id"] == nil)
  }

  @Test("Codex convenience HTTP wrapper rejects non-Codex managed-agent responses")
  func codexConvenienceWrapperRejectsUnexpectedManagedAgentFamily() async throws {
    StartSessionURLProtocol.reset(responseKind: .terminalSnapshot)
    let client = try makeClient()

    do {
      _ = try await client.startCodexRun(
        sessionID: "sess-1",
        request: CodexRunRequest(actor: nil, prompt: "Investigate", mode: .report)
      )
      Issue.record("Expected startCodexRun to reject terminal snapshots")
    } catch let error as HarnessMonitorAPIError {
      guard case .server(let code, let message) = error else {
        Issue.record("Unexpected error: \(error)")
        return
      }
      #expect(code == 500)
      #expect(message == "Managed Codex agent did not return a Codex snapshot")
    }
  }

  private func makeClient() throws -> HarnessMonitorAPIClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StartSessionURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let endpoint = try #require(URL(string: "http://127.0.0.1:9999"))
    return HarnessMonitorAPIClient(
      connection: HarnessMonitorConnection(
        endpoint: endpoint,
        token: "token"
      ),
      session: session
    )
  }
}

private final class StartSessionURLProtocol: URLProtocol, @unchecked Sendable {
  enum ResponseKind {
    case sessionStart
    case codexSnapshot
    case terminalSnapshot
  }

  struct RecordedRequest {
    let path: String
    let method: String
    let body: [String: Any]?
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var recordedRequests: [RecordedRequest] = []
  nonisolated(unsafe) private static var responseKind: ResponseKind = .sessionStart

  static var lastRequestPath: String? {
    lock.withLock { recordedRequests.last?.path }
  }

  static var lastRequestMethod: String? {
    lock.withLock { recordedRequests.last?.method }
  }

  static var records: [RecordedRequest] {
    lock.withLock { recordedRequests }
  }

  static func reset(responseKind: ResponseKind = .sessionStart) {
    lock.withLock {
      recordedRequests = []
      Self.responseKind = responseKind
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
      Self.recordedRequests.append(
        RecordedRequest(
          path: url.path,
          method: request.httpMethod ?? "",
          body: Self.jsonBody(for: request)
        )
      )
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

    let responseBody = Self.lock.withLock { Self.responseBody(for: Self.responseKind) }

    let data = Data(responseBody.utf8)
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  private static func jsonBody(for request: URLRequest) -> [String: Any]? {
    guard
      let data = bodyData(for: request),
      !data.isEmpty,
      let object = try? JSONSerialization.jsonObject(with: data),
      let body = object as? [String: Any]
    else {
      return nil
    }
    return body
  }

  private static func bodyData(for request: URLRequest) -> Data? {
    if let body = request.httpBody {
      return body
    }
    guard let stream = request.httpBodyStream else {
      return nil
    }
    stream.open()
    defer { stream.close() }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      guard count > 0 else { break }
      data.append(buffer, count: count)
    }
    return data
  }

  private static func responseBody(for responseKind: ResponseKind) -> String {
    switch responseKind {
    case .sessionStart:
      sessionStartResponseBody
    case .codexSnapshot:
      codexSnapshotResponseBody
    case .terminalSnapshot:
      terminalSnapshotResponseBody
    }
  }

  private static let sessionStartResponseBody =
    """
    {
      "state": {
        "schema_version": 9,
        "state_version": 0,
        "session_id": "sess-new-1",
        "project_name": "harness",
        "worktree_path": "/tmp/harness/workspace",
        "shared_path": "/tmp/harness/memory",
        "origin_path": "/Users/example/Projects/harness",
        "branch_ref": "main",
        "title": "test session",
        "context": "unit test context",
        "status": "awaiting_leader",
        "created_at": "2026-04-20T12:00:00Z",
        "updated_at": "2026-04-20T12:00:00Z",
        "agents": {},
        "tasks": {},
        "leader_id": null,
        "observe_id": null,
        "metrics": {
          "agent_count": 0,
          "active_agent_count": 0,
          "idle_agent_count": 0,
          "open_task_count": 0,
          "in_progress_task_count": 0,
          "blocked_task_count": 0,
          "completed_task_count": 0
        }
      }
    }
    """

  private static let codexSnapshotResponseBody =
    """
    {
      "kind": "codex",
      "snapshot": {
        "run_id": "codex-run-1",
        "session_id": "sess-1",
        "session_agent_id": "codex-worker",
        "display_name": "Codex Worker",
        "project_dir": "/tmp/harness",
        "thread_id": "thread-1",
        "turn_id": "turn-1",
        "mode": "workspace_write",
        "status": "running",
        "prompt": "Investigate",
        "latest_summary": "running",
        "final_message": null,
        "error": null,
        "pending_approvals": [],
        "resolved_approvals": [],
        "events": [],
        "created_at": "2026-04-20T12:00:00Z",
        "updated_at": "2026-04-20T12:00:01Z",
        "model": "gpt-5.5",
        "effort": "high"
      }
    }
    """

  private static let terminalSnapshotResponseBody =
    """
    {
      "kind": "terminal",
      "snapshot": {
        "tui_id": "tui-1",
        "session_id": "sess-1",
        "agent_id": "worker-1",
        "runtime": "codex",
        "status": "running",
        "argv": ["codex"],
        "project_dir": "/tmp/harness",
        "size": { "rows": 24, "cols": 80 },
        "screen": {
          "rows": 24,
          "cols": 80,
          "cursor_row": 1,
          "cursor_col": 1,
          "text": "ready"
        },
        "transcript_path": "/tmp/tui-1.log",
        "exit_code": null,
        "signal": null,
        "error": null,
        "created_at": "2026-04-20T12:00:00Z",
        "updated_at": "2026-04-20T12:00:01Z"
      }
    }
    """
}
