import Foundation
import Testing

@testable import HarnessMonitorKit

extension TaskBoardAPIClientTests {
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
    let runtimeConfig = try await client.taskBoardGitRuntimeConfig()
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
        githubInbox: TaskBoardGitHubInboxConfig(repositories: ["example/harness", "example/aff"]),
        policyVersion: "task-board-policy-v3"
      )
    )
    let updatedRuntimeConfig = try await client.updateTaskBoardGitRuntimeConfig(
      request: TaskBoardGitRuntimeConfig(
        repositoryOverrides: [
          TaskBoardGitRepositoryOverride(repository: "example/harness")
        ]
      )
    )
    let tokenSync = try await client.syncTaskBoardGitHubTokens(
      request: TaskBoardGitHubTokensSyncRequest(
        globalToken: "ghu_global",
        repositoryTokens: [
          TaskBoardGitHubRepositoryToken(repository: "example/harness", token: "ghu_repo")
        ]
      )
    )
    let todoistTokenSync = try await client.syncTaskBoardTodoistToken(
      request: TaskBoardTodoistTokenSyncRequest(token: "todoist-token")
    )

    #expect(status.settings.githubProject.owner == "example")
    #expect(status.settings.githubProject.repo == "harness")
    #expect(runtimeConfig.global.authorName == "Harness Bot")
    #expect(runOnce.lastRun?.sync.total == 1)
    #expect(runOnce.lastRun?.policyTraceIds == ["trace-1"])
    #expect(settings.githubInbox.repositories == ["example/harness", "example/aff"])
    #expect(settings.policyVersion == "task-board-policy-v3")
    #expect(updatedRuntimeConfig.repositoryOverrides.first?.repository == "example/harness")
    #expect(tokenSync.globalTokenConfigured == true)
    #expect(tokenSync.repositoryTokenCount == 1)
    #expect(todoistTokenSync.tokenConfigured == true)
    #expect(
      client.calls == [
        .startTaskBoardOrchestrator,
        .stopTaskBoardOrchestrator,
        .runTaskBoardOrchestratorOnce(
          itemID: nil,
          dryRun: false,
          status: .todo,
          projectDir: "/tmp/harness"
        ),
        .updateTaskBoardOrchestratorSettings(
          policyVersion: "task-board-policy-v3",
          clearProjectDir: true,
          clearDispatchStatusFilter: true
        ),
        .updateTaskBoardGitRuntimeConfig(overrideCount: 1),
        .syncTaskBoardGitHubTokens(globalTokenConfigured: true, repositoryTokenCount: 1),
        .syncTaskBoardTodoistToken(tokenConfigured: true),
      ]
    )
  }

  func taskBoardDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }
}
