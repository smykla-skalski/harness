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
      ]
    )
  }
}
