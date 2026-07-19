import Foundation
import Testing

@testable import HarnessMonitorKit

extension TaskBoardAPIClientTests {
  @Test("HTTP client reads automation history, detail, and metrics")
  func httpClientReadsTaskBoardAutomation() async throws {
    TaskBoardURLProtocol.reset()
    let client = try makeClient()

    let history = try await client.taskBoardAutomationRuns(
      request: TaskBoardAutomationHistoryRequest(limit: 25, before: "cursor/one")
    )
    let detail = try await client.taskBoardAutomationRunDetail(runID: "run/42 ?#%")
    let metrics = try await client.taskBoardAutomationMetrics()
    let records = TaskBoardURLProtocol.records

    #expect(records.count == 3)
    #expect(records[0].path == "/v1/task-board/orchestrator/runs")
    #expect(records[0].query?.contains("limit=25") == true)
    #expect(records[0].query?.contains("before=cursor/one") == true)
    #expect(
      records[1].percentEncodedPath
        == "/v1/task-board/orchestrator/runs/run%2F42%20%3F%23%25"
    )
    #expect(records[2].path == "/v1/task-board/orchestrator/metrics")
    #expect(history.runs.first?.runId == "run/42 ?#%")
    #expect(history.nextCursor == "cursor-2")
    #expect(detail.stages.first?.summary == "Reconciled one item")
    #expect(metrics.runsPartial == 1)
    #expect(metrics.runsCancelled == 1)
  }

  @Test("WebSocket transport reads automation history, detail, and metrics")
  func webSocketReadsTaskBoardAutomation() async throws {
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

    let history = try await transport.taskBoardAutomationRuns(
      request: TaskBoardAutomationHistoryRequest(limit: 25, before: "cursor/one")
    )
    let detail = try await transport.taskBoardAutomationRunDetail(runID: "run/42 ?#%")
    let metrics = try await transport.taskBoardAutomationMetrics()
    let calls = await probe.calls

    #expect(
      calls.map(\.method) == [
        .taskBoardOrchestratorRuns,
        .taskBoardOrchestratorRunDetail,
        .taskBoardOrchestratorMetrics,
      ]
    )
    guard case .object(let historyParams)? = calls[0].params else {
      Issue.record("Expected history RPC parameters")
      return
    }
    guard case .object(let detailParams)? = calls[1].params else {
      Issue.record("Expected detail RPC parameters")
      return
    }
    #expect(historyParams["limit"] == .number(25))
    #expect(historyParams["before"] == .string("cursor/one"))
    #expect(detailParams["run_id"] == .string("run/42 ?#%"))
    #expect(calls[2].params == nil)
    #expect(history.runs.first?.runId == detail.run.runId)
    #expect(metrics.openConflicts == 2)
  }
}
