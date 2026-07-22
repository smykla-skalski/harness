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

  @Test("HTTP client uses reviews route contract")
  func httpClientUsesReviewsRoutes() async throws {
    let result = try await performReviewsHTTPClientContractCalls()
    let records = TaskBoardURLProtocol.records

    assertReviewsHTTPRouteContract(records)
    assertReviewsHTTPBodyContract(records)
    assertReviewsHTTPClientResults(result)
  }

  @Test("WebSocket transport uses task-board RPC contract")
  func webSocketTransportUsesTaskBoardRPCContract() async throws {
    let result = try await performWebSocketContractCalls()

    assertWebSocketRPCContract(result.calls)
    assertWebSocketPayloadContract(result.calls)
    assertWebSocketResults(result)
  }

  @Test("HTTP client uses task-board position snapshot and mutation routes")
  func httpClientUsesTaskBoardPositionRoutes() async throws {
    TaskBoardURLProtocol.reset()
    let client = try makeClient()

    let list = try await client.taskBoardItemsSnapshot(status: .todo)
    let snapshot = try await client.taskBoardItemPositionSnapshot(id: "board-1")
    let set = try await client.setTaskBoardItemPosition(
      id: "board-1",
      request: TaskBoardSetItemPositionRequest(
        status: .todo, lanePosition: 0, expectedItemRevision: 7, expectedItemsChangeSeq: 42,
        actor: "monitor-client"
      )
    )
    let reset = try await client.resetTaskBoardItemPosition(
      id: "board-1",
      request: TaskBoardResetItemPositionRequest(
        expectedItemRevision: 8, expectedItemsChangeSeq: 43, actor: "monitor-client"
      )
    )
    let records = TaskBoardURLProtocol.records

    #expect(records.map(\.method) == ["GET", "GET", "PUT", "POST"])
    #expect(
      records.map(\.path) == [
        "/v1/task-board/items",
        "/v1/task-board/items/board-1/position",
        "/v1/task-board/items/board-1/position",
        "/v1/task-board/items/board-1/position/reset",
      ])
    #expect(records[0].query == "status=todo")
    #expect(records[2].body?["status"] as? String == "todo")
    #expect(records[2].body?["lane_position"] as? Int == 0)
    #expect(records[2].body?["expected_item_revision"] as? Int == 7)
    #expect(records[2].body?["expected_items_change_seq"] as? Int == 42)
    #expect(records[2].body?["actor"] as? String == "monitor-client")
    #expect(records[3].body?["expected_item_revision"] as? Int == 8)
    #expect(records[3].body?["expected_items_change_seq"] as? Int == 43)
    #expect(list.itemsChangeSeq == 42)
    #expect(list.itemRevisions == ["board-1": 7])
    #expect(snapshot.itemRevision == 7)
    #expect(snapshot.itemsChangeSeq == 42)
    #expect(set.snapshot.itemRevision == 8)
    #expect(reset.snapshot.itemsChangeSeq == 43)
  }

  @Test("WebSocket transport uses task-board position snapshot and mutation methods")
  func webSocketTransportUsesTaskBoardPositionMethods() async throws {
    let probe = RPCProbe()
    let transport = WebSocketTransport(
      connection: HarnessMonitorConnection(
        endpoint: try #require(URL(string: "http://127.0.0.1:1")), token: "token"
      ),
      session: URLSession(configuration: .ephemeral),
      rpcSender: { method, params, _ in
        await probe.record(method: method, params: params)
        return try taskBoardRPCResponse(for: method)
      }
    )

    let list = try await transport.taskBoardItemsSnapshot(status: .todo)
    let snapshot = try await transport.taskBoardItemPositionSnapshot(id: "board-1")
    let set = try await transport.setTaskBoardItemPosition(
      id: "board-1",
      request: TaskBoardSetItemPositionRequest(
        status: .todo, lanePosition: 0, expectedItemRevision: 7, expectedItemsChangeSeq: 42,
        actor: "monitor-client"
      )
    )
    let reset = try await transport.resetTaskBoardItemPosition(
      id: "board-1",
      request: TaskBoardResetItemPositionRequest(
        expectedItemRevision: 8, expectedItemsChangeSeq: 43, actor: "monitor-client"
      )
    )
    let calls = await probe.calls

    #expect(
      calls.map(\.method) == [
        .taskBoardList,
        .taskBoardPositionGet,
        .taskBoardPositionSet,
        .taskBoardPositionReset,
      ])
    #expect(positionObjectValue(calls[0].params, key: "status") == .string("todo"))
    #expect(positionObjectValue(calls[1].params, key: "id") == .string("board-1"))
    #expect(positionObjectValue(calls[2].params, key: "id") == .string("board-1"))
    #expect(positionObjectValue(calls[2].params, key: "lane_position") == .number(0))
    #expect(positionObjectValue(calls[2].params, key: "expected_item_revision") == .number(7))
    #expect(positionObjectValue(calls[2].params, key: "expected_items_change_seq") == .number(42))
    #expect(positionObjectValue(calls[2].params, key: "actor") == .string("monitor-client"))
    #expect(positionObjectValue(calls[3].params, key: "id") == .string("board-1"))
    #expect(positionObjectValue(calls[3].params, key: "expected_item_revision") == .number(8))
    #expect(positionObjectValue(calls[3].params, key: "expected_items_change_seq") == .number(43))
    #expect(list.itemsChangeSeq == 42)
    #expect(snapshot.itemRevision == 7)
    #expect(set.snapshot.itemRevision == 8)
    #expect(reset.snapshot.itemsChangeSeq == 43)
  }

  @Test("WebSocket transport uses reviews RPC contract")
  func webSocketTransportUsesReviewsRPCContract() async throws {
    let result = try await performReviewsWebSocketContractCalls()

    assertReviewsWebSocketRPCContract(result.calls)
    assertReviewsWebSocketPayloadContract(result.calls)
    assertReviewsWebSocketResults(result)
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
        stepMode: true,
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
    #expect(settings.stepMode)
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
          stepMode: true,
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

  private func positionObjectValue(_ value: JSONValue?, key: String) -> JSONValue? {
    guard case .object(let object)? = value else {
      return nil
    }
    return object[key]
  }
}
