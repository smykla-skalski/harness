import Foundation
import Testing

@testable import HarnessMonitorKit

extension TaskBoardAPIClientTests {
  @Test("HTTP client reads automation data and force-cancels an exact target")
  func httpClientReadsTaskBoardAutomation() async throws {
    TaskBoardURLProtocol.reset()
    let client = try makeClient()

    let history = try await client.taskBoardAutomationRuns(
      request: TaskBoardAutomationHistoryRequest(limit: 25, before: "cursor/one")
    )
    let detail = try await client.taskBoardAutomationRunDetail(runID: "run/42 ?#%")
    let metrics = try await client.taskBoardAutomationMetrics()
    let forceCancel = try await client.forceCancelTaskBoardAutomation(
      request: TaskBoardAutomationForceCancelRequest(
        target: cancelTarget(),
        reason: "operator requested cleanup",
        actor: "spoofed-actor"
      )
    )
    let records = TaskBoardURLProtocol.records

    #expect(records.count == 4)
    #expect(records[0].path == "/v1/task-board/orchestrator/runs")
    #expect(records[0].query?.contains("limit=25") == true)
    #expect(records[0].query?.contains("before=cursor/one") == true)
    #expect(
      records[1].percentEncodedPath
        == "/v1/task-board/orchestrator/runs/run%2F42%20%3F%23%25"
    )
    #expect(records[2].path == "/v1/task-board/orchestrator/metrics")
    #expect(records[3].path == "/v1/task-board/orchestrator/force-cancel")
    #expect(records[3].method == "POST")
    let targetBody = records[3].body?["target"] as? [String: Any]
    #expect(targetBody?["execution_id"] as? String == "execution-7")
    #expect(targetBody?["assignment_id"] as? String == "assignment-7")
    #expect(
      (targetBody?["fencing_epoch"] as? NSNumber)?.uint64Value
        == 9_007_199_254_740_993
    )
    #expect(targetBody?["expected_record_sha256"] as? String == "digest-7")
    #expect(records[3].body?["reason"] as? String == "operator requested cleanup")
    #expect(records[3].body?["actor"] as? String == "spoofed-actor")
    #expect(history.runs.first?.runId == "run/42 ?#%")
    #expect(history.nextCursor == "cursor-2")
    #expect(detail.stages.first?.summary == "Reconciled one item")
    #expect(metrics.runsPartial == 1)
    #expect(metrics.runsCancelled == 1)
    #expect(forceCancel.disposition == .acceptedPending)
  }

  @Test("WebSocket transport reads automation data and force-cancels an exact target")
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
    let forceCancel = try await transport.forceCancelTaskBoardAutomation(
      request: TaskBoardAutomationForceCancelRequest(
        target: cancelTarget(),
        reason: "operator requested cleanup"
      )
    )
    let calls = await probe.calls

    #expect(
      calls.map(\.method) == [
        .taskBoardOrchestratorRuns,
        .taskBoardOrchestratorRunDetail,
        .taskBoardOrchestratorMetrics,
        .taskBoardOrchestratorForceCancel,
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
    guard case .object(let forceCancelParams)? = calls[3].params,
      case .object(let forceCancelTarget)? = forceCancelParams["target"]
    else {
      Issue.record("Expected force-cancel RPC parameters")
      return
    }
    #expect(forceCancelTarget["execution_id"] == .string("execution-7"))
    #expect(forceCancelTarget["assignment_id"] == .string("assignment-7"))
    #expect(
      forceCancelTarget["fencing_epoch"]
        == .unsignedInteger(9_007_199_254_740_993)
    )
    #expect(forceCancelTarget["expected_record_sha256"] == .string("digest-7"))
    #expect(forceCancelParams["reason"] == .string("operator requested cleanup"))
    #expect(history.runs.first?.runId == detail.run.runId)
    #expect(metrics.openConflicts == 2)
    #expect(forceCancel.disposition == .acceptedPending)
  }

  private func cancelTarget() -> TaskBoardAutomationCancelTarget {
    TaskBoardAutomationCancelTarget(
      executionId: "execution-7",
      itemId: "item-7",
      workflowKind: .prReview,
      assignmentId: "assignment-7",
      hostId: "host-7",
      fencingEpoch: 9_007_199_254_740_993,
      actionKey: "review",
      attempt: 2,
      idempotencyKey: "idempotency-7",
      assignmentState: "running",
      expectedRecordSha256: "digest-7",
      cancelPending: false
    )
  }
}
