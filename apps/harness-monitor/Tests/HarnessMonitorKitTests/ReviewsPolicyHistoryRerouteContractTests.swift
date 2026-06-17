import Foundation
import Testing

@testable import HarnessMonitorKit

/// Proves reviewsPolicyHistory decodes through the generated
/// ReviewsPolicyHistoryResponseWire graph on the plain PolicyWireCoding decoder
/// on BOTH transports. History previously existed only on the HTTP client; the
/// WebSocket transport now implements it too (the .reviewsPolicyHistory RPC
/// method already existed), so the two transports are at parity. The daemon
/// emits snake_case (workflow_id, pull_request_number, by_trigger, recorded_at,
/// run_id) and the wire types own that shape.
@Suite("Reviews policy history decode reroute")
struct ReviewsPolicyHistoryRerouteContractTests {
  private var request: ReviewsPolicyHistoryRequest {
    ReviewsPolicyHistoryRequest(
      subject: ReviewsPolicySubject(repository: "example/harness", pullRequestNumber: 42)
    )
  }

  @Test("HTTP client decodes policy history through the wire types")
  func httpPolicyHistoryReroute() async throws {
    TaskBoardURLProtocol.reset()
    let client = try makeHTTPClient()

    let response = try await client.reviewsPolicyHistory(request)

    try assertHistory(response)
  }

  @Test("WebSocket transport decodes policy history through the wire types")
  func webSocketPolicyHistoryReroute() async throws {
    let probe = RPCProbe()
    let transport = try makeWebSocketTransport(probe: probe)

    let response = try await transport.reviewsPolicyHistory(request)

    try assertHistory(response)

    let methods = await probe.calls.map(\.method)
    #expect(methods == [.reviewsPolicyHistory])
  }

  private func assertHistory(_ response: ReviewsPolicyHistoryResponse) throws {
    #expect(response.workflowID == "reviews_auto")
    #expect(response.subject.repository == "example/harness")
    #expect(response.subject.pullRequestNumber == 42)

    #expect(response.runs.count == 1)
    let run = try #require(response.runs.first)
    #expect(run.runID == "run-42")
    #expect(run.trigger == .manual)
    #expect(run.status == .completed)

    #expect(response.metrics.total == 1)
    #expect(response.metrics.completed == 1)
    #expect(response.metrics.byTrigger["manual"] == 1)

    #expect(response.timeline.map(\.event) == ["started", "completed"])
    #expect(response.timeline.first?.runID == "run-42")
  }

  private func makeHTTPClient() throws -> HarnessMonitorAPIClient {
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

  private func makeWebSocketTransport(probe: RPCProbe) throws -> WebSocketTransport {
    WebSocketTransport(
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
  }
}
