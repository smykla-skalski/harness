import Foundation
import HarnessMonitorCore
import HarnessMonitorMirrorStore
import XCTest

final class MobileRemoteDaemonCommandRouteTests: XCTestCase {
  override func tearDown() {
    RemoteDaemonCommandURLProtocol.reset()
    super.tearDown()
  }

  func testPermissionAndTaskBoardCommandsUseWriteRoutes() async throws {
    var requests = try await submit(
      makeRemoteDaemonCommand(
        kind: .acpPermissionDecision,
        agentID: "agent-1",
        payload: ["batchID": "batch-1", "decision": "approve_all"]
      )
    )
    var request = try XCTUnwrap(requests.last)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.path, "/v1/managed-agents/agent-1/permission-batches/batch-1")
    XCTAssertEqual(try commandRequestJSON(request)["decision"] as? String, "approve_all")

    requests = try await submit(
      makeRemoteDaemonCommand(
        kind: .taskBoardDispatch,
        taskID: "task-1",
        payload: [
          "status": "todo",
          "dryRun": "false",
          "projectDir": "/workspace/project",
        ]
      )
    )
    request = try XCTUnwrap(requests.last)
    let dispatch = try commandRequestJSON(request)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.path, "/v1/task-board/dispatch")
    XCTAssertEqual(dispatch["item_id"] as? String, "task-1")
    XCTAssertEqual(dispatch["status"] as? String, "todo")
    XCTAssertEqual(dispatch["dry_run"] as? Bool, false)
    XCTAssertEqual(dispatch["project_dir"] as? String, "/workspace/project")

    requests = try await submit(
      makeRemoteDaemonCommand(kind: .taskBoardPlanApproval, taskID: "task-1")
    )
    request = try XCTUnwrap(requests.last)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.path, "/v1/task-board/items/task-1/planning/approve")
    XCTAssertEqual(try commandRequestJSON(request)["approved_by"] as? String, "ios-device")
  }

  func testAgentStartCommandsRouteEveryRuntimeFamily() async throws {
    var requests = try await submit(
      makeRemoteDaemonCommand(
        kind: .agentStart,
        sessionID: "session-1",
        payload: ["agent": "codex", "role": "worker", "prompt": "continue"]
      )
    )
    var request = try XCTUnwrap(requests.last)
    var body = try commandRequestJSON(request)
    XCTAssertEqual(request.url?.path, "/v1/sessions/session-1/managed-agents/codex")
    XCTAssertEqual(body["prompt"] as? String, "continue")
    XCTAssertEqual(body["mode"] as? String, "workspace_write")

    requests = try await submit(
      makeRemoteDaemonCommand(
        kind: .agentStart,
        sessionID: "session-1",
        payload: [
          "agent": "terminal:claude",
          "role": "reviewer",
          "prompt": "inspect",
          "rows": "40",
          "cols": "100",
        ]
      )
    )
    request = try XCTUnwrap(requests.last)
    body = try commandRequestJSON(request)
    XCTAssertEqual(request.url?.path, "/v1/sessions/session-1/managed-agents/terminal")
    XCTAssertEqual(body["runtime"] as? String, "claude")
    XCTAssertEqual(body["role"] as? String, "reviewer")
    XCTAssertEqual(body["rows"] as? Int, 40)
    XCTAssertEqual(body["cols"] as? Int, 100)

    requests = try await submit(
      makeRemoteDaemonCommand(
        kind: .agentStart,
        sessionID: "session-1",
        payload: [
          "agent": "acp:copilot",
          "role": "worker",
          "recordPermissions": "true",
        ]
      )
    )
    request = try XCTUnwrap(requests.last)
    body = try commandRequestJSON(request)
    XCTAssertEqual(request.url?.path, "/v1/sessions/session-1/managed-agents/acp")
    XCTAssertEqual(body["descriptor_id"] as? String, "copilot")
    XCTAssertEqual(body["record_permissions"] as? Bool, true)
  }

  func testAgentStopCommandsResolveRuntimeBeforeMutation() async throws {
    let routes: [(String, String, String)] = [
      ("terminal", "POST", "/v1/managed-agents/agent-1/stop"),
      ("codex", "POST", "/v1/managed-agents/agent-1/interrupt"),
      ("acp", "DELETE", "/v1/managed-agents/agent-1"),
    ]
    for (kind, method, path) in routes {
      let requests = try await submit(
        makeRemoteDaemonCommand(kind: .agentStop, agentID: "agent-1"),
        responseBodies: [#"{"kind":"\#(kind)"}"#, "{}"]
      )

      XCTAssertEqual(requests.map(\.url?.path), ["/v1/managed-agents/agent-1", path])
      XCTAssertEqual(requests.last?.httpMethod, method)
    }
  }

  func testAgentPromptCommandsResolveRuntimeBeforeMutation() async throws {
    let routes: [(String, String)] = [
      ("terminal", "/v1/managed-agents/agent-1/input"),
      ("codex", "/v1/managed-agents/agent-1/steer"),
      ("acp", "/v1/managed-agents/agent-1/prompt"),
    ]
    for (kind, path) in routes {
      let requests = try await submit(
        makeRemoteDaemonCommand(
          kind: .agentPrompt,
          agentID: "agent-1",
          payload: ["prompt": "continue"]
        ),
        responseBodies: [#"{"kind":"\#(kind)"}"#, "{}"]
      )
      let request = try XCTUnwrap(requests.last)
      let body = try commandRequestJSON(request)

      XCTAssertEqual(request.url?.path, path)
      if kind == "terminal" {
        let input = try XCTUnwrap(body["input"] as? [String: Any])
        XCTAssertEqual(input["type"] as? String, "text")
        XCTAssertEqual(input["text"] as? String, "continue\n")
      } else {
        XCTAssertEqual(body["prompt"] as? String, "continue")
      }
    }
  }

  func testPullRequestCommandsUseReviewMutationRoutes() async throws {
    let routes: [(MobileCommandKind, String, [String: String])] = [
      (.pullRequestApprove, "/v1/reviews/approve", [:]),
      (.pullRequestLabel, "/v1/reviews/labels", ["label": "ready"]),
      (.pullRequestRerunChecks, "/v1/reviews/rerun-checks", [:]),
      (.pullRequestMerge, "/v1/reviews/merge", ["method": "squash"]),
    ]
    for (kind, path, extraPayload) in routes {
      var payload = [
        "repository": "owner/repo",
        "number": "42",
        "pullRequestID": "stale-pr",
        "repositoryID": "stale-repo",
        "headSha": "stale-sha",
        "mergeable": "unknown",
      ]
      payload.merge(extraPayload) { _, new in new }
      let requests = try await submit(
        makeRemoteDaemonCommand(
          kind: kind,
          reviewID: "owner/repo#42",
          payload: payload
        ),
        responseBodies: [remoteResolvedReviewResponse, "{}"]
      )
      XCTAssertEqual(
        requests.map(\.url?.path),
        ["/v1/reviews/pull-requests/resolve", path]
      )

      let resolveBody = try commandRequestJSON(try XCTUnwrap(requests.first))
      let references = try XCTUnwrap(resolveBody["references"] as? [[String: Any]])
      XCTAssertEqual(references.first?["repository"] as? String, "owner/repo")
      XCTAssertEqual(references.first?["number"] as? Int, 42)
      XCTAssertEqual(resolveBody["backport_detection_enabled"] as? Bool, true)
      XCTAssertNil(resolveBody["backport_patterns"])

      let request = try XCTUnwrap(requests.last)
      let body = try commandRequestJSON(request)
      let targets = try XCTUnwrap(body["targets"] as? [[String: Any]])
      let target = try XCTUnwrap(targets.first)

      XCTAssertEqual(request.url?.path, path)
      XCTAssertEqual(target["repository"] as? String, "owner/repo")
      XCTAssertEqual(target["number"] as? Int, 42)
      XCTAssertEqual(target["pull_request_id"] as? String, "fresh-pr")
      XCTAssertEqual(target["repository_id"] as? String, "fresh-repo")
      XCTAssertEqual(target["head_sha"] as? String, "fresh-sha")
      XCTAssertEqual(target["mergeable"] as? String, "mergeable")
      XCTAssertEqual(target["review_status"] as? String, "approved")
      XCTAssertEqual(target["check_status"] as? String, "failure")
      XCTAssertEqual(target["policy_blocked"] as? Bool, true)
      XCTAssertEqual(target["viewer_can_update"] as? Bool, false)
      XCTAssertEqual(target["viewer_can_merge_as_admin"] as? Bool, true)
      XCTAssertEqual(target["required_failed_check_names"] as? [String], ["required/ci"])
      XCTAssertEqual(target["check_suite_ids"] as? [String], ["suite-fresh"])
      XCTAssertEqual(target["has_conflict_markers"] as? Bool, true)
      XCTAssertEqual(target["viewer_has_active_approval"] as? Bool, true)
      XCTAssertEqual(target["auto_merge_enabled"] as? Bool, false)
      XCTAssertEqual(
        target["approval_requirement_satisfied_after_viewer_approval"] as? Bool,
        true
      )
      if let (key, value) = extraPayload.first {
        XCTAssertEqual(body[key] as? String, value)
      }
    }
  }

  func testPullRequestCommandFailsClosedWhenReviewCannotBeResolved() async throws {
    RemoteDaemonCommandURLProtocol.reset()
    RemoteDaemonCommandURLProtocol.enqueue(
      body: #"{"fetched_at":"2026-07-10T12:00:00Z","items":[],"missing_references":[]}"#
    )
    let client = try makeRemoteDaemonCommandClient()
    let command = makeRemoteDaemonCommand(
      kind: .pullRequestApprove,
      reviewID: "owner/repo#42",
      payload: ["repository": "owner/repo", "number": "42"]
    )

    do {
      _ = try await client.queueCommand(command, currentRevision: 42, now: command.createdAt)
      XCTFail("unresolved review command should fail")
    } catch {
      XCTAssertEqual(
        error as? MobileRemoteDaemonSyncError,
        .invalidCommand("remote daemon did not resolve owner/repo#42")
      )
    }
    XCTAssertEqual(
      RemoteDaemonCommandURLProtocol.requests.map(\.url?.path),
      ["/v1/reviews/pull-requests/resolve"]
    )
  }

  func testRefreshCommandsUseScopeSpecificReadOrSyncRoutes() async throws {
    let routes: [(String, String, String, [String: String])] = [
      ("health", "GET", "/v1/health", [:]),
      ("mobileMirror", "GET", "/v1/sessions", [:]),
      ("reviews", "POST", "/v1/reviews/refresh", ["repository": "owner/repo", "number": "42"]),
      ("taskBoard", "POST", "/v1/task-board/sync", [:]),
      ("sessionTasks", "GET", "/v1/sessions/session-1", [:]),
    ]
    for (scope, method, path, extraPayload) in routes {
      var payload = ["scope": scope]
      payload.merge(extraPayload) { _, new in new }
      let requests = try await submit(
        makeRemoteDaemonCommand(
          kind: .refresh,
          sessionID: scope == "sessionTasks" ? "session-1" : nil,
          reviewID: scope == "reviews" ? "owner/repo#42" : nil,
          payload: payload
        ),
        responseBodies: scope == "reviews" ? [remoteResolvedReviewResponse, "{}"] : ["{}"]
      )

      XCTAssertEqual(requests.last?.httpMethod, method)
      XCTAssertEqual(requests.last?.url?.path, path)
      if scope == "reviews" {
        XCTAssertEqual(
          requests.map(\.url?.path),
          ["/v1/reviews/pull-requests/resolve", "/v1/reviews/refresh"]
        )
        let body = try commandRequestJSON(try XCTUnwrap(requests.last))
        let targets = try XCTUnwrap(body["targets"] as? [[String: Any]])
        XCTAssertEqual(targets.first?["pull_request_id"] as? String, "fresh-pr")
        XCTAssertEqual(targets.first?["head_sha"] as? String, "fresh-sha")
      }
    }
  }

  func testCommandIdentifiersAreEncodedAsSinglePathComponents() async throws {
    let requests = try await submit(
      makeRemoteDaemonCommand(
        kind: .acpPermissionDecision,
        agentID: "agent/one",
        payload: ["batchID": "batch/two", "decision": "deny_all"]
      )
    )

    XCTAssertEqual(
      requests.last?.url?.absoluteString,
      "https://daemon.example.com/v1/managed-agents/agent%2Fone/permission-batches/batch%2Ftwo"
    )
  }

  private func submit(
    _ command: MobileCommandRecord,
    responseBodies: [String] = ["{}"]
  ) async throws -> [URLRequest] {
    RemoteDaemonCommandURLProtocol.reset()
    for body in responseBodies {
      RemoteDaemonCommandURLProtocol.enqueue(body: body)
    }
    let client = try makeRemoteDaemonCommandClient()
    _ = try await client.queueCommand(command, currentRevision: 42, now: command.createdAt)
    let requests = RemoteDaemonCommandURLProtocol.requests
    for request in requests {
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer server-token")
      XCTAssertEqual(
        request.value(forHTTPHeaderField: "x-harness-remote-client-id"),
        "ios-device"
      )
    }
    return requests
  }
}
