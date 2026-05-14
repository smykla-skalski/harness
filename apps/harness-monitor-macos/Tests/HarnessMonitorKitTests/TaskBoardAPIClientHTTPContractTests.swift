import Foundation
import Testing

@testable import HarnessMonitorKit

extension TaskBoardAPIClientTests {
  func performHTTPClientContractCalls() async throws -> TaskBoardHTTPContractResult {
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
    let sync = try await client.syncTaskBoard(
      request: TaskBoardSyncRequest(
        status: .todo,
        provider: .gitHub,
        direction: .push,
        dryRun: false
      )
    )
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
      sync: sync,
      evaluation: evaluation,
      status: status,
      runOnce: runOnce,
      updatedSettings: updatedSettings
    )
  }

  func assertHTTPRouteContract(_ records: [TaskBoardURLProtocol.RecordedRequest]) {
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
    #expect(records[3].body?["clear_session_id"] as? Bool == true)
    #expect(records[3].body?["clear_work_item_id"] as? Bool == true)
    #expect(records[5].body?["status"] as? String == "todo")
    #expect(records[5].body?["provider"] as? String == "git_hub")
    #expect(records[5].body?["direction"] as? String == "push")
    #expect(records[5].body?["dry_run"] as? Bool == false)
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

  func assertHTTPClientResults(_ result: TaskBoardHTTPContractResult) {
    #expect(result.sync.providers.first?.provider == .gitHub)
    #expect(result.sync.operations.first?.action == .push)
    #expect(result.sync.operations.first?.boardItemId == "board-1")
    #expect(result.sync.operations.first?.applied == true)
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
}

struct TaskBoardHTTPContractResult {
  let dispatch: TaskBoardDispatchSummary
  let sync: TaskBoardSyncSummary
  let evaluation: TaskBoardEvaluationSummary
  let status: TaskBoardOrchestratorStatus
  let runOnce: TaskBoardOrchestratorRunOnceResponse
  let updatedSettings: TaskBoardOrchestratorSettings
}
