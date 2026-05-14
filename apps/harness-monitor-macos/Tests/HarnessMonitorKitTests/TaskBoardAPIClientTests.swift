import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Task-board daemon API client", .serialized)
struct TaskBoardAPIClientTests {
  @Test("HTTP client uses task-board route contract")
  func httpClientUsesTaskBoardRoutes() async throws {
    let result = try await performHTTPClientContractCalls()
    let records = TaskBoardURLProtocol.records

    assertHTTPRouteContract(records)
    assertHTTPBodyContract(records)
    assertHTTPClientResults(result)
  }

  @Test("WebSocket transport uses task-board RPC contract")
  func webSocketTransportUsesTaskBoardRPCContract() async throws {
    let result = try await performWebSocketContractCalls()

    assertWebSocketRPCContract(result.calls)
    assertWebSocketPayloadContract(result.calls)
    assertWebSocketResults(result)
  }

  @Test("Recording client implements task-board orchestrator contract")
  func recordingClientImplementsTaskBoardOrchestratorContract() async throws {
    let client = RecordingHarnessClient()

    let status = try await client.taskBoardOrchestratorStatus()
    _ = try await client.taskBoardOrchestratorSettings()
    _ = try await client.startTaskBoardOrchestrator()
    _ = try await client.stopTaskBoardOrchestrator()
    let runOnce = try await client.runTaskBoardOrchestratorOnce(
      request: TaskBoardOrchestratorRunOnceRequest(
        dryRun: false,
        status: .todo,
        projectDir: "/tmp/harness"
      )
    )
    let settings = try await client.updateTaskBoardOrchestratorSettings(
      request: TaskBoardOrchestratorSettingsUpdateRequest(
        clearDispatchStatusFilter: true,
        clearProjectDir: true,
        policyVersion: "task-board-policy-v3"
      )
    )

    #expect(status.settings.githubProject.owner == "kong")
    #expect(status.settings.githubProject.repo == "harness")
    #expect(runOnce.lastRun?.sync.total == 1)
    #expect(runOnce.lastRun?.policyTraceIds == ["trace-1"])
    #expect(settings.policyVersion == "task-board-policy-v3")
    #expect(
      client.calls == [
        .startTaskBoardOrchestrator,
        .stopTaskBoardOrchestrator,
        .runTaskBoardOrchestratorOnce(dryRun: false, status: .todo, projectDir: "/tmp/harness"),
        .updateTaskBoardOrchestratorSettings(
          policyVersion: "task-board-policy-v3",
          clearProjectDir: true,
          clearDispatchStatusFilter: true
        ),
      ]
    )
  }

  private func performHTTPClientContractCalls() async throws -> TaskBoardHTTPContractResult {
    TaskBoardURLProtocol.reset()
    let client = try makeClient()

    _ = try await client.taskBoardItems(status: .todo)
    _ = try await client.taskBoardItem(id: "board-1")
    _ = try await client.createTaskBoardItem(
      request: TaskBoardCreateItemRequest(
        title: "Board item",
        body: "Body",
        priority: .high,
        agentMode: .interactive,
        tags: ["automation"],
        projectId: "project-1",
        sessionId: "sess-1",
        workItemId: "task-1",
        id: "board-1"
      )
    )
    _ = try await client.updateTaskBoardItem(
      id: "board-1",
      request: TaskBoardUpdateItemRequest(
        status: .inProgress,
        clearSessionId: true,
        clearWorkItemId: true
      )
    )
    _ = try await client.deleteTaskBoardItem(id: "board-1")
    _ = try await client.syncTaskBoard(status: .todo)
    let dispatch = try await client.dispatchTaskBoard(
      status: .todo,
      dryRun: false,
      projectDir: "/tmp/harness"
    )
    let evaluation = try await client.evaluateTaskBoard(status: .inProgress, dryRun: false)
    _ = try await client.auditTaskBoard(status: .blocked)
    let status = try await client.taskBoardOrchestratorStatus()
    _ = try await client.startTaskBoardOrchestrator()
    _ = try await client.stopTaskBoardOrchestrator()
    let runOnce = try await client.runTaskBoardOrchestratorOnce()
    _ = try await client.taskBoardOrchestratorSettings()
    let updatedSettings = try await client.updateTaskBoardOrchestratorSettings(
      request: TaskBoardOrchestratorSettingsUpdateRequest(
        enabledWorkflows: [.defaultTask, .prFix],
        dryRunDefault: false,
        dispatchStatusFilter: .planReview,
        clearDispatchStatusFilter: false,
        projectDir: "/tmp/next",
        clearProjectDir: false,
        githubProject: TaskBoardGitHubProjectConfig(
          owner: "kong",
          repo: "harness",
          checkoutPath: "/tmp/harness",
          protectedPaths: [TaskBoardProtectedPathRule(pattern: "src/security")],
          enabledAutomations: TaskBoardGitHubAutomationToggles(enabled: [
            .syncTaskBoard, .autoMerge,
          ])
        ),
        policyVersion: "task-board-policy-v3"
      )
    )
    _ = try await client.taskBoardProjects(status: .todo)
    _ = try await client.taskBoardMachines(status: .todo)

    return TaskBoardHTTPContractResult(
      dispatch: dispatch,
      evaluation: evaluation,
      status: status,
      runOnce: runOnce,
      updatedSettings: updatedSettings
    )
  }

  private func assertHTTPRouteContract(_ records: [TaskBoardURLProtocol.RecordedRequest]) {
    #expect(
      records.map(\.method)
        == [
          "GET", "GET", "POST", "PUT", "DELETE", "POST", "POST", "POST", "GET", "GET", "POST",
          "POST", "POST", "GET", "PUT", "GET", "GET",
        ]
    )
    #expect(
      records.map(\.path)
        == [
          "/v1/task-board/items",
          "/v1/task-board/items/board-1",
          "/v1/task-board/items",
          "/v1/task-board/items/board-1",
          "/v1/task-board/items/board-1",
          "/v1/task-board/sync",
          "/v1/task-board/dispatch",
          "/v1/task-board/evaluate",
          "/v1/task-board/audit",
          "/v1/task-board/orchestrator/status",
          "/v1/task-board/orchestrator/start",
          "/v1/task-board/orchestrator/stop",
          "/v1/task-board/orchestrator/run-once",
          "/v1/task-board/orchestrator/settings",
          "/v1/task-board/orchestrator/settings",
          "/v1/task-board/projects",
          "/v1/task-board/machines",
        ]
    )
  }

  private func assertHTTPBodyContract(_ records: [TaskBoardURLProtocol.RecordedRequest]) {
    #expect(records[0].query == "status=todo")
    #expect(records[2].body?["body"] as? String == "Body")
    #expect(records[2].body?["agent_mode"] as? String == "interactive")
    #expect(records[2].body?["tags"] as? [String] == ["automation"])
    #expect(records[2].body?["project_id"] as? String == "project-1")
    #expect(records[2].body?["session_id"] as? String == "sess-1")
    #expect(records[2].body?["work_item_id"] as? String == "task-1")
    #expect(records[2].body?["id"] as? String == "board-1")
    #expect(records[3].body?["status"] as? String == "in_progress")
    #expect(records[3].body?["clear_session_id"] as? Bool == true)
    #expect(records[3].body?["clear_work_item_id"] as? Bool == true)
    #expect(records[5].body?["status"] as? String == "todo")
    #expect(records[6].body?["status"] as? String == "todo")
    #expect(records[6].body?["dry_run"] as? Bool == false)
    #expect(records[6].body?["project_dir"] as? String == "/tmp/harness")
    #expect(records[7].body?["status"] as? String == "in_progress")
    #expect(records[7].body?["dry_run"] as? Bool == false)
    #expect(records[8].query == "status=blocked")
    #expect(records[12].body?.isEmpty == true)
    #expect(records[14].body?["enabled_workflows"] as? [String] == ["default_task", "pr_fix"])
    #expect(records[14].body?["dry_run_default"] as? Bool == false)
    #expect(records[14].body?["dispatch_status_filter"] as? String == "plan_review")
    #expect(records[14].body?["clear_dispatch_status_filter"] as? Bool == false)
    #expect(records[14].body?["project_dir"] as? String == "/tmp/next")
    #expect(records[14].body?["clear_project_dir"] as? Bool == false)
    let githubProject = records[14].body?["github_project"] as? [String: Any]
    #expect(githubProject?["owner"] as? String == "kong")
    #expect(githubProject?["repo"] as? String == "harness")
    #expect(githubProject?["checkout_path"] as? String == "/tmp/harness")
    #expect(githubProject?["merge_method"] as? String == "squash")
    let enabledAutomations = githubProject?["enabled_automations"] as? [String: Any]
    #expect(enabledAutomations?["enabled"] as? [String] == ["sync_task_board", "auto_merge"])
    #expect(records[14].body?["policy_version"] as? String == "task-board-policy-v3")
    #expect(records[15].query == "status=todo")
    #expect(records[16].query == "status=todo")
  }

  private func assertHTTPClientResults(_ result: TaskBoardHTTPContractResult) {
    #expect(result.dispatch.plans.first?.task.title == "Board item")
    #expect(result.dispatch.plans.first?.policy?.decision == "allow")
    #expect(result.dispatch.applied.first?.workItemId == "task-1")
    #expect(result.evaluation.records.first?.outcome == .completed)
    #expect(result.evaluation.updated == 1)
    #expect(result.status.currentTick?.phase == .evaluation)
    #expect(result.status.lastRun?.evaluation?.completed == 1)
    #expect(result.status.lastRun?.policyTraceIds == ["trace-1"])
    #expect(result.status.workflowExecutionCounts.first?.status == .completed)
    #expect(result.status.workflowExecutionCounts.first?.count == 3)
    #expect(result.runOnce.lastRun?.evaluation?.updated == 1)
    #expect(result.runOnce.lastRun?.policyTraceIds == ["trace-1"])
    #expect(result.runOnce.lastRun?.dispatch?.applied.first?.workItemId == "task-1")
    #expect(result.updatedSettings.policyVersion == "task-board-policy-v2")
  }

  private func performWebSocketContractCalls() async throws -> TaskBoardWebSocketContractResult {
    let probe = RPCProbe()
    let transport = WebSocketTransport(
      connection: HarnessMonitorConnection(
        endpoint: try #require(URL(string: "http://127.0.0.1:1")),
        token: "token"
      ),
      session: URLSession(configuration: .ephemeral),
      rpcSender: { method, params, _ in
        await probe.record(method: method, params: params)
        return try taskBoardRPCResponse(for: method)
      }
    )

    _ = try await transport.taskBoardItems(status: TaskBoardStatus.todo)
    _ = try await transport.taskBoardItem(id: "board-1")
    _ = try await transport.createTaskBoardItem(
      request: TaskBoardCreateItemRequest(title: "Board item"))
    _ = try await transport.updateTaskBoardItem(
      id: "board-1",
      request: TaskBoardUpdateItemRequest(status: .done)
    )
    _ = try await transport.deleteTaskBoardItem(id: "board-1")
    _ = try await transport.syncTaskBoard(status: TaskBoardStatus.todo)
    let dispatch = try await transport.dispatchTaskBoard(
      status: TaskBoardStatus.todo,
      dryRun: false,
      projectDir: "/tmp/harness"
    )
    let evaluation = try await transport.evaluateTaskBoard(
      status: TaskBoardStatus.inProgress,
      dryRun: false
    )
    _ = try await transport.auditTaskBoard(status: TaskBoardStatus.blocked)
    let status = try await transport.taskBoardOrchestratorStatus()
    _ = try await transport.startTaskBoardOrchestrator()
    _ = try await transport.stopTaskBoardOrchestrator()
    let runOnce = try await transport.runTaskBoardOrchestratorOnce()
    _ = try await transport.taskBoardOrchestratorSettings()
    _ = try await transport.updateTaskBoardOrchestratorSettings(
      request: TaskBoardOrchestratorSettingsUpdateRequest(
        enabledWorkflows: [.defaultTask, .prFix],
        dryRunDefault: false,
        dispatchStatusFilter: .planReview,
        projectDir: "/tmp/next",
        githubProject: TaskBoardGitHubProjectConfig(
          owner: "kong",
          repo: "harness",
          checkoutPath: "/tmp/harness",
          enabledAutomations: TaskBoardGitHubAutomationToggles(enabled: [.autoMerge])
        ),
        policyVersion: "task-board-policy-v3"
      )
    )
    _ = try await transport.taskBoardProjects(status: .todo)
    _ = try await transport.taskBoardMachines(status: .todo)

    let calls = await probe.calls
    return TaskBoardWebSocketContractResult(
      calls: calls,
      dispatch: dispatch,
      evaluation: evaluation,
      status: status,
      runOnce: runOnce
    )
  }

  private func assertWebSocketRPCContract(_ calls: [RPCProbe.Call]) {
    #expect(
      calls.map(\.method)
        == [
          .taskBoardList,
          .taskBoardGet,
          .taskBoardCreate,
          .taskBoardUpdate,
          .taskBoardDelete,
          .taskBoardSync,
          .taskBoardDispatch,
          .taskBoardEvaluate,
          .taskBoardAudit,
          .taskBoardOrchestratorStatus,
          .taskBoardOrchestratorStart,
          .taskBoardOrchestratorStop,
          .taskBoardOrchestratorRunOnce,
          .taskBoardOrchestratorSettingsGet,
          .taskBoardOrchestratorSettingsUpdate,
          .taskBoardProjects,
          .taskBoardMachines,
        ]
    )
  }

  private func assertWebSocketPayloadContract(_ calls: [RPCProbe.Call]) {
    #expect(objectValue(calls[0].params, key: "status") == .string("todo"))
    #expect(objectValue(calls[1].params, key: "id") == .string("board-1"))
    #expect(objectValue(calls[3].params, key: "id") == .string("board-1"))
    #expect(objectValue(calls[3].params, key: "status") == .string("done"))
    #expect(objectValue(calls[6].params, key: "status") == .string("todo"))
    #expect(objectValue(calls[6].params, key: "dry_run") == .bool(false))
    #expect(objectValue(calls[6].params, key: "project_dir") == .string("/tmp/harness"))
    #expect(objectValue(calls[7].params, key: "status") == .string("in_progress"))
    #expect(objectValue(calls[7].params, key: "dry_run") == .bool(false))
    #expect(objectValue(calls[8].params, key: "status") == .string("blocked"))
    #expect(calls[9].params == nil)
    #expect(calls[10].params == nil)
    #expect(calls[11].params == nil)
    #expect(calls[12].params == .object([:]))
    #expect(calls[13].params == nil)
    #expect(
      objectValue(calls[14].params, key: "enabled_workflows")
        == .array([
          .string("default_task"),
          .string("pr_fix"),
        ]))
    #expect(objectValue(calls[14].params, key: "dry_run_default") == .bool(false))
    #expect(objectValue(calls[14].params, key: "dispatch_status_filter") == .string("plan_review"))
    if case .object(let githubProject)? = objectValue(calls[14].params, key: "github_project") {
      #expect(githubProject["owner"] == .string("kong"))
      #expect(githubProject["repo"] == .string("harness"))
      #expect(githubProject["checkout_path"] == .string("/tmp/harness"))
      #expect(
        githubProject["enabled_automations"]
          == .object(["enabled": .array([.string("auto_merge")])])
      )
    } else {
      Issue.record("Expected github_project object in websocket settings update")
    }
    #expect(objectValue(calls[14].params, key: "policy_version") == .string("task-board-policy-v3"))
    #expect(objectValue(calls[15].params, key: "status") == .string("todo"))
    #expect(objectValue(calls[16].params, key: "status") == .string("todo"))
  }

  private func assertWebSocketResults(_ result: TaskBoardWebSocketContractResult) {
    #expect(result.dispatch.plans.first?.task.title == "Board item")
    #expect(result.dispatch.plans.first?.policy?.decision == "allow")
    #expect(result.dispatch.applied.first?.workItemId == "task-1")
    #expect(result.evaluation.records.first?.outcome == .completed)
    #expect(result.status.currentTick?.phase == .evaluation)
    #expect(result.runOnce.lastRun?.evaluation?.updated == 1)
    #expect(result.runOnce.lastRun?.policyTraceIds == ["trace-1"])
  }

  private func makeClient() throws -> HarnessMonitorAPIClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TaskBoardURLProtocol.self]
    let session = URLSession(configuration: configuration)
    return HarnessMonitorAPIClient(
      connection: HarnessMonitorConnection(
        endpoint: try #require(URL(string: "http://127.0.0.1:9999")),
        token: "token"
      ),
      session: session
    )
  }

  private func objectValue(_ value: JSONValue?, key: String) -> JSONValue? {
    guard case .object(let object)? = value else {
      return nil
    }
    return object[key]
  }
}

private struct TaskBoardHTTPContractResult {
  let dispatch: TaskBoardDispatchSummary
  let evaluation: TaskBoardEvaluationSummary
  let status: TaskBoardOrchestratorStatus
  let runOnce: TaskBoardOrchestratorRunOnceResponse
  let updatedSettings: TaskBoardOrchestratorSettings
}

private struct TaskBoardWebSocketContractResult {
  let calls: [RPCProbe.Call]
  let dispatch: TaskBoardDispatchSummary
  let evaluation: TaskBoardEvaluationSummary
  let status: TaskBoardOrchestratorStatus
  let runOnce: TaskBoardOrchestratorRunOnceResponse
}
