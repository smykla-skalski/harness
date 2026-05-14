import Foundation
import Testing

@testable import HarnessMonitorKit

extension TaskBoardAPIClientTests {
  func performWebSocketContractCalls() async throws -> TaskBoardWebSocketContractResult {
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
    let sync = try await transport.syncTaskBoard(
      request: TaskBoardSyncRequest(
        status: .todo,
        provider: .gitHub,
        direction: .push,
        dryRun: false
      )
    )
    let dispatch = try await transport.dispatchTaskBoard(
      request: TaskBoardDispatchRequest(
        status: TaskBoardStatus.todo,
        itemId: "board-1",
        dryRun: false,
        projectDir: "/tmp/harness"
      )
    )
    let evaluation = try await transport.evaluateTaskBoard(
      request: TaskBoardEvaluateRequest(
        status: TaskBoardStatus.inProgress,
        itemId: "board-1",
        dryRun: false
      )
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
    let runtimeConfig = try await transport.taskBoardGitRuntimeConfig()
    let updatedRuntimeConfig = try await transport.updateTaskBoardGitRuntimeConfig(
      request: TaskBoardGitRuntimeConfig(
        global: TaskBoardGitRuntimeProfile(
          authorName: "Harness Bot",
          authorEmail: "bot@example.com",
          sshKeyPath: "/Users/test/.ssh/id_ed25519",
          signing: TaskBoardGitSigningConfig(
            mode: .ssh,
            sshKeyPath: "/Users/test/.ssh/id_signing"
          )
        ),
        repositoryOverrides: [
          TaskBoardGitRepositoryOverride(
            repository: "kong/harness",
            profile: TaskBoardGitRuntimeProfile(
              authorName: "Repo Bot",
              authorEmail: "repo@example.com",
              sshKeyPath: "/Users/test/.ssh/id_repo",
              signing: TaskBoardGitSigningConfig(mode: .gpg, gpgKeyId: "ABC123")
            )
          )
        ]
      )
    )
    let tokenSync = try await transport.syncTaskBoardGitHubTokens(
      request: TaskBoardGitHubTokensSyncRequest(
        globalToken: "ghu_global",
        repositoryTokens: [
          TaskBoardGitHubRepositoryToken(repository: "kong/harness", token: "ghu_repo")
        ]
      )
    )
    _ = try await transport.taskBoardProjects(status: .todo)
    _ = try await transport.taskBoardMachines(status: .todo)

    let calls = await probe.calls
    return TaskBoardWebSocketContractResult(
      calls: calls,
      sync: sync,
      dispatch: dispatch,
      evaluation: evaluation,
      status: status,
      runOnce: runOnce,
      runtimeConfig: runtimeConfig,
      updatedRuntimeConfig: updatedRuntimeConfig,
      tokenSync: tokenSync
    )
  }

  func assertWebSocketRPCContract(_ calls: [RPCProbe.Call]) {
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
          .taskBoardOrchestratorRuntimeConfigGet,
          .taskBoardOrchestratorRuntimeConfigUpdate,
          .taskBoardOrchestratorGitHubTokensSync,
          .taskBoardProjects,
          .taskBoardMachines,
        ]
    )
  }

  func assertWebSocketPayloadContract(_ calls: [RPCProbe.Call]) {
    #expect(objectValue(calls[0].params, key: "status") == .string("todo"))
    #expect(objectValue(calls[1].params, key: "id") == .string("board-1"))
    #expect(objectValue(calls[3].params, key: "id") == .string("board-1"))
    #expect(objectValue(calls[3].params, key: "status") == .string("done"))
    #expect(objectValue(calls[5].params, key: "status") == .string("todo"))
    #expect(objectValue(calls[5].params, key: "provider") == .string("git_hub"))
    #expect(objectValue(calls[5].params, key: "direction") == .string("push"))
    #expect(objectValue(calls[5].params, key: "dry_run") == .bool(false))
    #expect(objectValue(calls[6].params, key: "status") == .string("todo"))
    #expect(objectValue(calls[6].params, key: "item_id") == .string("board-1"))
    #expect(objectValue(calls[6].params, key: "dry_run") == .bool(false))
    #expect(objectValue(calls[6].params, key: "project_dir") == .string("/tmp/harness"))
    #expect(objectValue(calls[7].params, key: "status") == .string("in_progress"))
    #expect(objectValue(calls[7].params, key: "item_id") == .string("board-1"))
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
    #expect(calls[15].params == nil)
    #expect(objectValue(calls[16].params, key: "global") != nil)
    #expect(objectValue(calls[17].params, key: "global_token") == .string("ghu_global"))
    if case .array(let repositoryTokens)? = objectValue(calls[17].params, key: "repository_tokens") {
      if case .object(let token)? = repositoryTokens.first {
        #expect(token["repository"] == .string("kong/harness"))
        #expect(token["token"] == .string("ghu_repo"))
      } else {
        Issue.record("Expected repository token object in websocket token sync payload")
      }
    } else {
      Issue.record("Expected repository_tokens array in websocket token sync payload")
    }
    #expect(objectValue(calls[18].params, key: "status") == .string("todo"))
    #expect(objectValue(calls[19].params, key: "status") == .string("todo"))
  }

  func assertWebSocketResults(_ result: TaskBoardWebSocketContractResult) {
    #expect(result.sync.providers.first?.provider == .gitHub)
    #expect(result.sync.operations.first?.action == .push)
    #expect(result.sync.operations.first?.boardItemId == "board-1")
    #expect(result.sync.operations.first?.applied == true)
    #expect(result.dispatch.plans.first?.task.title == "Board item")
    #expect(result.dispatch.plans.first?.policy?.decision == "allow")
    #expect(result.dispatch.applied.first?.workItemId == "task-1")
    #expect(result.dispatch.applied.first?.item.workflow?.prNumber == 42)
    #expect(result.evaluation.records.first?.outcome == .completed)
    #expect(result.status.currentTick?.phase == .evaluation)
    #expect(result.runOnce.lastRun?.evaluation?.updated == 1)
    #expect(result.runOnce.lastRun?.policyTraceIds == ["trace-1"])
    #expect(result.runtimeConfig.global.authorEmail == "bot@example.com")
    #expect(result.updatedRuntimeConfig.repositoryOverrides.first?.profile.signing.mode == .gpg)
    #expect(result.tokenSync.repositoryTokenCount == 1)
  }

  private func objectValue(_ value: JSONValue?, key: String) -> JSONValue? {
    guard case .object(let object)? = value else {
      return nil
    }
    return object[key]
  }
}

struct TaskBoardWebSocketContractResult {
  let calls: [RPCProbe.Call]
  let sync: TaskBoardSyncSummary
  let dispatch: TaskBoardDispatchSummary
  let evaluation: TaskBoardEvaluationSummary
  let status: TaskBoardOrchestratorStatus
  let runOnce: TaskBoardOrchestratorRunOnceResponse
  let runtimeConfig: TaskBoardGitRuntimeConfig
  let updatedRuntimeConfig: TaskBoardGitRuntimeConfig
  let tokenSync: TaskBoardGitHubTokensSyncResponse
}
