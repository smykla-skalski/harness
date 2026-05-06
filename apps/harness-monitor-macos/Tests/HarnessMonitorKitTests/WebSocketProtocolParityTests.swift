import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("WebSocket protocol parity routing")
struct WebSocketProtocolParityTests {
  actor RPCProbe {
    struct Call: Equatable, Sendable {
      let method: WebSocketRPCMethod
      let params: JSONValue?
    }

    private(set) var calls: [Call] = []

    func record(method: WebSocketRPCMethod, params: JSONValue?) {
      calls.append(Call(method: method, params: params))
    }

    func snapshot() -> [Call] { calls }
  }

  let session = URLSession(configuration: .ephemeral)
  static let testEndpoint: URL = {
    guard let url = URL(string: "http://127.0.0.1:8080") else {
      preconditionFailure("Invalid test endpoint URL literal")
    }
    return url
  }()

  @Test("WebSocket transport routes parity mutations over typed RPC methods")
  func parityMutationsUseTypedRPCMethods() async throws {
    let probe = RPCProbe()
    let terminalSnapshot = sampleTerminalSnapshot()
    let codexSnapshot = sampleCodexSnapshot()
    let transport = makeRPCTransport(probe: probe)

    try await exerciseParityMutations(
      transport: transport,
      terminalSnapshot: terminalSnapshot,
      codexSnapshot: codexSnapshot
    )

    let calls = await probe.snapshot()
    assertExpectedMethods(calls)
    assertExpectedParameters(
      calls: calls,
      terminalSnapshot: terminalSnapshot,
      codexSnapshot: codexSnapshot
    )
  }

  @Test("WebSocket transport query params carry explicit identity aliases")
  func parityQueriesUseExplicitIdentityAliases() async throws {
    let probe = RPCProbe()
    let transport = makeQueryRPCTransport(probe: probe)

    try await exerciseParityQueries(transport: transport)

    let calls = await probe.snapshot()
    assertExpectedQueryParameters(calls)
  }

  @Test("WebSocket session-agent mutations carry explicit identity aliases")
  func paritySessionAgentMutationsUseExplicitIdentityAliases() async throws {
    let probe = RPCProbe()
    let transport = makeSessionAgentMutationRPCTransport(probe: probe)

    try await exerciseSessionAgentMutations(transport: transport)

    let calls = await probe.snapshot()
    assertExpectedSessionAgentMutationParameters(calls)
  }

  @Test("Swift RPC method catalog matches daemon websocket constants")
  func swiftRPCMethodCatalogMatchesDaemonConstants() throws {
    let daemonMethods = try daemonRPCMethodValues()
    let swiftMethods = Set(WebSocketRPCMethod.allCases.map(\.rawValue))

    #expect(swiftMethods == daemonMethods)
  }

}
