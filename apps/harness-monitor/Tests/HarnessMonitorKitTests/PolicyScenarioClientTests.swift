import Foundation
import HarnessMonitorPolicyModels
import Testing

@testable import HarnessMonitorKit

@Suite("Policy scenario client", .serialized)
struct PolicyScenarioClientTests {
  @Test("HTTP client uses scenario route contract")
  func httpClientUsesScenarioRoutes() async throws {
    TaskBoardURLProtocol.reset()
    let client = try makeClient()
    let input = PolicyInput(action: .mergePr)

    _ = try await client.createPolicyScenario(
      request: PolicyScenarioCreateRequest(name: "Merge", input: input)
    )
    _ = try await client.updatePolicyScenario(
      request: PolicyScenarioUpdateRequest(
        id: "scenario-1",
        name: "Merge red",
        input: input
      )
    )
    _ = try await client.deletePolicyScenario(
      request: PolicyScenarioDeleteRequest(id: "scenario-1")
    )
    _ = try await client.resetPolicyScenarios(
      request: PolicyScenarioResetRequest()
    )

    let records = TaskBoardURLProtocol.records
    #expect(records.map(\.method) == ["POST", "POST", "POST", "POST"])
    #expect(
      records.map(\.path)
        == [
          "/v1/policy-scenarios/create",
          "/v1/policy-scenarios/update",
          "/v1/policy-scenarios/delete",
          "/v1/policy-scenarios/reset",
        ]
    )
    #expect(records[0].body?["name"] as? String == "Merge")
    let createInput = records[0].body?["input"] as? [String: Any]
    #expect(createInput?["action"] as? String == "merge_pr")
    #expect(records[1].body?["id"] as? String == "scenario-1")
    #expect(records[1].body?["name"] as? String == "Merge red")
    #expect(records[2].body?["id"] as? String == "scenario-1")
  }

  @Test("WebSocket transport uses scenario RPC contract")
  func webSocketTransportUsesScenarioRPCContract() async throws {
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
    let input = PolicyInput(action: .mergePr)

    _ = try await transport.createPolicyScenario(
      request: PolicyScenarioCreateRequest(name: "Merge", input: input)
    )
    _ = try await transport.updatePolicyScenario(
      request: PolicyScenarioUpdateRequest(
        id: "scenario-1",
        name: "Merge red",
        input: input
      )
    )
    _ = try await transport.deletePolicyScenario(
      request: PolicyScenarioDeleteRequest(id: "scenario-1")
    )
    _ = try await transport.resetPolicyScenarios(
      request: PolicyScenarioResetRequest()
    )

    let calls = await probe.calls
    #expect(
      calls.map(\.method)
        == [
          .policyScenarioCreate,
          .policyScenarioUpdate,
          .policyScenarioDelete,
          .policyScenarioReset,
        ]
    )
    #expect(objectValue(calls[0].params, key: "name") == .string("Merge"))
    #expect(objectValue(calls[1].params, key: "id") == .string("scenario-1"))
    #expect(objectValue(calls[2].params, key: "id") == .string("scenario-1"))
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

  private func objectValue(_ value: JSONValue?, key: String) -> JSONValue? {
    guard case .object(let object)? = value else {
      return nil
    }
    return object[key]
  }
}
