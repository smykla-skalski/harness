import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Task board review report")
struct TaskBoardReviewReportTests {
  @Test("Generated wire response decodes every report state")
  func decodesEveryState() throws {
    let decoder = PolicyWireCoding.decoder
    let payloads = [
      #"{"status":"not_started"}"#,
      #"""
      {
        "status":"running",
        "execution_id":"execution-1",
        "runtime":"openrouter",
        "actual_runtime":"openrouter",
        "requested_model":"deepseek/deepseek-v4-flash",
        "head_revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "started_at":"2026-07-29T19:40:00Z"
      }
      """#,
      #"""
      {
        "status":"terminal",
        "execution_id":"execution-1",
        "execution_state":"failed",
        "runtime":"openrouter",
        "actual_runtime":"openrouter",
        "requested_model":"deepseek/deepseek-v4-flash",
        "head_revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "started_at":"2026-07-29T19:40:00Z",
        "finished_at":"2026-07-29T19:41:00Z"
      }
      """#,
      sampleTaskBoardReviewReportText,
      sampleTaskBoardReviewReportText.replacingOccurrences(
        of: #""status": "completed""#,
        with: #""status": "failed""#
      ).replacingOccurrences(
        of: #""summary": "One actionable finding.","#,
        with: #""terminal_reason": "runtime exited","#
      ),
      sampleTaskBoardReviewReportText.replacingOccurrences(
        of: #""status": "completed""#,
        with: #""status": "cancelled""#
      ).replacingOccurrences(
        of: #""summary": "One actionable finding.","#,
        with: #""terminal_reason": "cancelled by operator","#
      ),
    ]

    let responses = try payloads.map {
      try decoder.decode(TaskBoardAiReviewReportResponse.self, from: Data($0.utf8))
    }

    #expect(responses.count == 6)
    guard case .notStarted = responses[0] else {
      Issue.record("Expected not-started response")
      return
    }
    guard case .running(_, let runtime, _, let actualRuntime, let model, _, _) = responses[1] else {
      Issue.record("Expected running response")
      return
    }
    #expect(runtime == "openrouter")
    #expect(actualRuntime == "openrouter")
    #expect(model == "deepseek/deepseek-v4-flash")
    guard case .terminal(
      _,
      let state,
      _,
      let requestedRuntime,
      let actualRuntime,
      _,
      _,
      _,
      _
    ) = responses[2] else {
      Issue.record("Expected terminal execution response")
      return
    }
    #expect(state == .failed)
    #expect(requestedRuntime == "openrouter")
    #expect(actualRuntime == "openrouter")
    guard case .completed(let completed) = responses[3] else {
      Issue.record("Expected completed response")
      return
    }
    #expect(completed.findings.first?.location.path == "src/review.rs")
    guard case .failed(let failed) = responses[4] else {
      Issue.record("Expected failed response")
      return
    }
    #expect(failed.terminalReason == "runtime exited")
    guard case .cancelled(let cancelled) = responses[5] else {
      Issue.record("Expected cancelled response")
      return
    }
    #expect(cancelled.terminalReason == "cancelled by operator")
  }

  @Test("Stale report comparison uses the item's exact current head")
  func detectsStaleHead() {
    let report = TaskBoardAiReviewReportRecord(
      reportId: "report-1",
      itemId: "item-1",
      correlationId: "correlation-1",
      repository: "example/harness",
      pullRequestNumber: 42,
      headRevision: String(repeating: "a", count: 40),
      runtime: "openrouter",
      requestedRuntime: "openrouter",
      actualRuntime: "openrouter",
      requestedModel: "deepseek/deepseek-v4-flash",
      status: .completed,
      summary: "Done",
      startedAt: "2026-07-29T19:40:00Z",
      finishedAt: "2026-07-29T19:41:12Z"
    )

    #expect(!report.isStale(comparedWith: nil))
    #expect(!report.isStale(comparedWith: String(repeating: "a", count: 40)))
    #expect(report.isStale(comparedWith: String(repeating: "b", count: 40)))
  }
}

extension TaskBoardAPIClientTests {
  @Test("HTTP client reads the selected item review report")
  func httpClientReadsReviewReport() async throws {
    TaskBoardURLProtocol.reset()
    let client = try makeClient()

    let response = try await client.taskBoardItemReviewReport(id: "board-1")
    await #expect(throws: (any Error).self) {
      _ = try await client.taskBoardItemReviewReport(id: "../unsafe")
    }

    #expect(
      TaskBoardURLProtocol.records.map(\.path) == [
        "/v1/task-board/items/board-1/review-report"
      ])
    guard case .completed(let report) = response else {
      Issue.record("Expected completed response")
      return
    }
    #expect(report.summary == "One actionable finding.")
  }

  @Test("WebSocket client reads the selected item review report")
  func webSocketClientReadsReviewReport() async throws {
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

    let response = try await transport.taskBoardItemReviewReport(id: "board-1")
    let calls = await probe.calls

    #expect(calls.map(\.method) == [.taskBoardReviewReportGet])
    guard case .object(let params)? = calls[0].params else {
      Issue.record("Expected object parameters")
      return
    }
    #expect(params["id"] == .string("board-1"))
    guard case .completed(let report) = response else {
      Issue.record("Expected completed response")
      return
    }
    #expect(report.findings.count == 1)
  }
}
