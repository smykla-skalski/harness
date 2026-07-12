import Foundation
import Testing

@testable import HarnessMonitorKit

extension TaskBoardAPIClientTests {
  func performHTTPClientContractCalls() async throws -> TaskBoardHTTPContractResult {
    TaskBoardURLProtocol.reset()
    let client = try makeClient()

    try await performHTTPItemCalls(client)
    let workflow = try await performHTTPWorkflowCalls(client)
    let orchestrator = try await performHTTPOrchestratorCalls(client)
    let settings = try await performHTTPSettingsCalls(client)
    let tokenSync = try await performHTTPGitHubTokenCalls(client)
    let todoistTokenSync = try await performHTTPTodoistTokenCalls(client)
    try await performHTTPDiscoveryCalls(client)
    let planning = try await performHTTPPlanningCalls(client)
    try await performHTTPSecretHandoffCalls(client)

    return TaskBoardHTTPContractResult(
      planning: planning,
      dispatch: workflow.dispatch,
      sync: workflow.sync,
      evaluation: workflow.evaluation,
      status: orchestrator.status,
      runOnce: orchestrator.runOnce,
      updatedSettings: settings.updatedSettings,
      runtimeConfig: settings.runtimeConfig,
      updatedRuntimeConfig: settings.updatedRuntimeConfig,
      tokenSync: tokenSync,
      todoistTokenSync: todoistTokenSync
    )
  }

  private func performHTTPItemCalls(_ client: HarnessMonitorAPIClient) async throws {
    _ = try await client.taskBoardItems(status: .todo)
    _ = try await client.taskBoardItem(id: "board-1")
    _ = try await client.createTaskBoardItem(request: httpCreateItemRequest())
    _ = try await client.updateTaskBoardItem(id: "board-1", request: httpUpdateItemRequest())
    _ = try await client.deleteTaskBoardItem(id: "board-1")
  }

  private func performHTTPWorkflowCalls(
    _ client: HarnessMonitorAPIClient
  ) async throws -> TaskBoardHTTPWorkflowResult {
    let sync = try await client.syncTaskBoard(
      request: TaskBoardSyncRequest(
        status: .todo,
        provider: .gitHub,
        direction: .push,
        dryRun: false
      )
    )
    let dispatch = try await client.dispatchTaskBoard(
      request: TaskBoardDispatchRequest(
        status: .todo,
        itemId: "board-1",
        dryRun: false,
        projectDir: "/tmp/harness"
      )
    )
    let evaluation = try await client.evaluateTaskBoard(
      request: TaskBoardEvaluateRequest(status: .inProgress, itemId: "board-1", dryRun: false)
    )
    _ = try await client.auditTaskBoard(status: .failed)
    return TaskBoardHTTPWorkflowResult(sync: sync, dispatch: dispatch, evaluation: evaluation)
  }

  private func performHTTPOrchestratorCalls(
    _ client: HarnessMonitorAPIClient
  ) async throws -> TaskBoardHTTPOrchestratorResult {
    let status = try await client.taskBoardOrchestratorStatus()
    _ = try await client.startTaskBoardOrchestrator()
    _ = try await client.stopTaskBoardOrchestrator()
    let runOnce = try await client.runTaskBoardOrchestratorOnce()
    return TaskBoardHTTPOrchestratorResult(status: status, runOnce: runOnce)
  }

  private func performHTTPSettingsCalls(
    _ client: HarnessMonitorAPIClient
  ) async throws -> TaskBoardHTTPSettingsResult {
    _ = try await client.taskBoardOrchestratorSettings()
    let updatedSettings = try await client.updateTaskBoardOrchestratorSettings(
      request: TaskBoardOrchestratorSettingsUpdateRequest(
        enabledWorkflows: [.defaultTask, .prFix],
        dryRunDefault: false,
        dispatchStatusFilter: .agenticReview,
        clearDispatchStatusFilter: false,
        projectDir: "/tmp/next",
        clearProjectDir: false,
        githubProject: TaskBoardGitHubProjectConfig(
          owner: "example",
          repo: "harness",
          checkoutPath: "/tmp/harness",
          protectedPaths: [TaskBoardProtectedPathRule(pattern: "src/security")],
          enabledAutomations: TaskBoardGitHubAutomationToggles(enabled: [
            .syncTaskBoard, .autoMerge,
          ])
        ),
        githubInbox: TaskBoardGitHubInboxConfig(repositories: ["example/harness", "example/aff"]),
        policyVersion: "task-board-policy-v3"
      )
    )
    let runtimeConfig = try await client.taskBoardGitRuntimeConfig()
    let updatedRuntimeConfig = try await client.updateTaskBoardGitRuntimeConfig(
      request: taskBoardRuntimeConfigUpdateRequest()
    )
    return TaskBoardHTTPSettingsResult(
      updatedSettings: updatedSettings,
      runtimeConfig: runtimeConfig,
      updatedRuntimeConfig: updatedRuntimeConfig
    )
  }

  private func performHTTPGitHubTokenCalls(
    _ client: HarnessMonitorAPIClient
  ) async throws -> TaskBoardGitHubTokensSyncResponse {
    try await client.syncTaskBoardGitHubTokens(
      request: TaskBoardGitHubTokensSyncRequest(
        globalToken: "ghu_global",
        repositoryTokens: [
          TaskBoardGitHubRepositoryToken(repository: "example/harness", token: "ghu_repo")
        ]
      )
    )
  }

  private func performHTTPTodoistTokenCalls(
    _ client: HarnessMonitorAPIClient
  ) async throws -> TaskBoardTodoistTokenSyncResponse {
    try await client.syncTaskBoardTodoistToken(
      request: TaskBoardTodoistTokenSyncRequest(token: "todoist-token")
    )
  }

  private func performHTTPDiscoveryCalls(_ client: HarnessMonitorAPIClient) async throws {
    _ = try await client.taskBoardProjects(status: .todo)
    _ = try await client.taskBoardMachines(status: .todo)
  }

  private func performHTTPPlanningCalls(
    _ client: HarnessMonitorAPIClient
  ) async throws -> TaskBoardPlanningResponse {
    _ = try await client.beginTaskBoardPlan(id: "board-1")
    _ = try await client.submitTaskBoardPlan(
      id: "board-1",
      request: TaskBoardPlanSubmitRequest(summary: "Use the semantic plan.")
    )
    return try await client.approveTaskBoardPlan(
      id: "board-1",
      request: TaskBoardPlanApproveRequest(
        approvedBy: "lead",
        approvedAt: "2026-05-14T02:00:00Z"
      )
    )
  }

  private func httpCreateItemRequest() -> TaskBoardCreateItemRequest {
    TaskBoardCreateItemRequest(
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
  }

  private func performHTTPSecretHandoffCalls(_ client: HarnessMonitorAPIClient) async throws {
    let prepared = try await client.prepareTaskBoardGitRuntimeSecretHandoff()
    #expect(prepared.migrationID == "migration-1")
    _ = try await client.acknowledgeTaskBoardGitRuntimeSecretHandoff(
      request: TaskBoardGitRuntimeSecretHandoffAckRequest(
        migrationID: "migration-1",
        digest: "digest-1"
      )
    )
    let capabilities = try await client.taskBoardCapabilities()
    #expect(capabilities.instanceID == "task-board-instance-1")
    _ = try await client.syncTaskBoardGitRuntimeKeyMaterial(
      request: TaskBoardGitRuntimeKeyMaterialSyncRequest(
        runtime: taskBoardRuntimeConfigUpdateRequest()
      )
    )
  }

  private func httpUpdateItemRequest() -> TaskBoardUpdateItemRequest {
    TaskBoardUpdateItemRequest(
      status: .inProgress,
      clearPlanning: true,
      clearWorkflow: true,
      clearSessionId: true,
      clearWorkItemId: true
    )
  }

  func assertHTTPRouteContract(_ records: [TaskBoardURLProtocol.RecordedRequest]) {
    #expect(
      records.map(\.method)
        == [
          "GET", "GET", "POST", "PUT", "DELETE", "POST", "POST", "POST", "GET", "GET", "POST",
          "POST", "POST", "GET", "PUT", "GET", "PUT", "PUT", "PUT", "GET", "GET", "POST",
          "POST", "POST", "POST", "POST", "GET", "PUT",
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
          "/v1/task-board/orchestrator/runtime-config",
          "/v1/task-board/orchestrator/runtime-config",
          "/v1/task-board/orchestrator/github-tokens",
          "/v1/task-board/orchestrator/todoist-token",
          "/v1/task-board/projects",
          "/v1/task-board/machines",
          "/v1/task-board/items/board-1/planning/begin",
          "/v1/task-board/items/board-1/planning/submit",
          "/v1/task-board/items/board-1/planning/approve",
          "/v1/task-board/git/runtime/secret-handoff/prepare",
          "/v1/task-board/git/runtime/secret-handoff/ack",
          "/v1/task-board/capabilities",
          "/v1/task-board/git/runtime/key-material",
        ]
    )
  }

  func assertHTTPBodyContract(_ records: [TaskBoardURLProtocol.RecordedRequest]) {
    #expect(records[0].query == "status=todo")
    #expect(records[2].body?["body"] as? String == "Body")
    #expect(records[2].body?["agent_mode"] as? String == "interactive")
    #expect(records[2].body?["tags"] as? [String] == ["automation"])
    #expect(records[2].body?["project_id"] as? String == "project-1")
    #expect(records[2].body?["session_id"] as? String == "sess-1")
    #expect(records[2].body?["work_item_id"] as? String == "task-1")
    #expect(records[2].body?["id"] as? String == "board-1")
    #expect(records[3].body?["status"] as? String == "in_progress")
    #expect(records[3].body?["clear_planning"] as? Bool == true)
    #expect(records[3].body?["clear_workflow"] as? Bool == true)
    #expect(records[3].body?["clear_session_id"] as? Bool == true)
    #expect(records[3].body?["clear_work_item_id"] as? Bool == true)
    #expect(records[5].body?["status"] as? String == "todo")
    #expect(records[5].body?["provider"] as? String == "git_hub")
    #expect(records[5].body?["direction"] as? String == "push")
    #expect(records[5].body?["dry_run"] as? Bool == false)
    #expect(records[6].body?["status"] as? String == "todo")
    #expect(records[6].body?["item_id"] as? String == "board-1")
    #expect(records[6].body?["dry_run"] as? Bool == false)
    #expect(records[6].body?["project_dir"] as? String == "/tmp/harness")
    #expect(records[7].body?["status"] as? String == "in_progress")
    #expect(records[7].body?["item_id"] as? String == "board-1")
    #expect(records[7].body?["dry_run"] as? Bool == false)
    #expect(records[8].query == "status=failed")
    #expect(records[12].body?.isEmpty == true)
    #expect(records[14].body?["enabled_workflows"] as? [String] == ["default_task", "pr_fix"])
    #expect(records[14].body?["dry_run_default"] as? Bool == false)
    #expect(records[14].body?["dispatch_status_filter"] as? String == "agentic_review")
    #expect(records[14].body?["clear_dispatch_status_filter"] as? Bool == false)
    #expect(records[14].body?["project_dir"] as? String == "/tmp/next")
    #expect(records[14].body?["clear_project_dir"] as? Bool == false)
    let githubProject = records[14].body?["github_project"] as? [String: Any]
    #expect(githubProject?["owner"] as? String == "example")
    #expect(githubProject?["repo"] as? String == "harness")
    #expect(githubProject?["checkout_path"] as? String == "/tmp/harness")
    #expect(githubProject?["merge_method"] as? String == "squash")
    let enabledAutomations = githubProject?["enabled_automations"] as? [String: Any]
    #expect(enabledAutomations?["enabled"] as? [String] == ["sync_task_board", "auto_merge"])
    let githubInbox = records[14].body?["github_inbox"] as? [String: Any]
    #expect(githubInbox?["repositories"] as? [String] == ["example/harness", "example/aff"])
    #expect(records[14].body?["policy_version"] as? String == "task-board-policy-v3")
    #expect(records[15].body == nil)
    let runtimeGlobal = records[16].body?["global"] as? [String: Any]
    #expect(runtimeGlobal?["author_name"] as? String == "Harness Bot")
    #expect(runtimeGlobal?["author_email"] as? String == "bot@example.com")
    let runtimeSigning = runtimeGlobal?["signing"] as? [String: Any]
    #expect(runtimeSigning?["mode"] as? String == "ssh")
    #expect(runtimeSigning?["ssh_key_path"] as? String == "/Users/test/.ssh/id_signing")
    #expect(records[17].body?["global_token"] as? String == "ghu_global")
    let repositoryTokens = records[17].body?["repository_tokens"] as? [[String: Any]]
    #expect(repositoryTokens?.first?["repository"] as? String == "example/harness")
    #expect(repositoryTokens?.first?["token"] as? String == "ghu_repo")
    #expect(records[18].body?["token"] as? String == "todoist-token")
    #expect(records[19].query == "status=todo")
    #expect(records[20].query == "status=todo")
    #expect(records[21].body?.isEmpty == true)
    #expect(records[22].body?["summary"] as? String == "Use the semantic plan.")
    #expect(records[23].body?["approved_by"] as? String == "lead")
    #expect(records[23].body?["approved_at"] as? String == "2026-05-14T02:00:00Z")
    #expect(records[24].body?.isEmpty == true)
    #expect(records[25].body?["migration_id"] as? String == "migration-1")
    #expect(records[25].body?["digest"] as? String == "digest-1")
    #expect(records[26].body == nil)
    #expect((records[27].body?["runtime"] as? [String: Any]) != nil)
  }

}

struct TaskBoardHTTPContractResult {
  let planning: TaskBoardPlanningResponse
  let dispatch: TaskBoardDispatchSummary
  let sync: TaskBoardSyncSummary
  let evaluation: TaskBoardEvaluationSummary
  let status: TaskBoardOrchestratorStatus
  let runOnce: TaskBoardOrchestratorRunOnceResponse
  let updatedSettings: TaskBoardOrchestratorSettings
  let runtimeConfig: TaskBoardGitRuntimeConfig
  let updatedRuntimeConfig: TaskBoardGitRuntimeConfig
  let tokenSync: TaskBoardGitHubTokensSyncResponse
  let todoistTokenSync: TaskBoardTodoistTokenSyncResponse
}

private struct TaskBoardHTTPWorkflowResult {
  let sync: TaskBoardSyncSummary
  let dispatch: TaskBoardDispatchSummary
  let evaluation: TaskBoardEvaluationSummary
}

private struct TaskBoardHTTPOrchestratorResult {
  let status: TaskBoardOrchestratorStatus
  let runOnce: TaskBoardOrchestratorRunOnceResponse
}

private struct TaskBoardHTTPSettingsResult {
  let updatedSettings: TaskBoardOrchestratorSettings
  let runtimeConfig: TaskBoardGitRuntimeConfig
  let updatedRuntimeConfig: TaskBoardGitRuntimeConfig
}
