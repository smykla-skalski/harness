import Foundation
import HarnessMonitorPolicyModels
import Testing

@testable import HarnessMonitorKit

@Suite("Policy canvas daemon API client", .serialized)
struct PolicyCanvasAPIClientTests {
  @Test("HTTP client uses policy-canvas library route contract")
  func httpClientUsesPolicyCanvasLibraryRoutes() async throws {
    TaskBoardURLProtocol.reset()
    let client = try makePolicyAPIClient()

    let workspace = try await client.policyCanvasWorkspace()
    let created = try await client.createPolicyCanvas(
      request: PolicyCanvasCreateRequest(title: "Experiment A")
    )
    let duplicated = try await client.duplicatePolicyCanvas(
      request: PolicyCanvasDuplicateRequest(
        canvasId: "canvas-primary",
        title: "Experiment B"
      )
    )
    let renamed = try await client.renamePolicyCanvas(
      request: PolicyCanvasRenameRequest(
        canvasId: "canvas-primary",
        title: "Default"
      )
    )
    let activated = try await client.activatePolicyCanvas(
      request: PolicyCanvasActivateRequest(canvasId: "canvas-experiment")
    )
    let deleted = try await client.deletePolicyCanvas(
      request: PolicyCanvasDeleteRequest(canvasId: "canvas-secondary")
    )

    let records = TaskBoardURLProtocol.records
    #expect(records.map(\.method) == ["GET", "POST", "POST", "POST", "POST", "POST"])
    #expect(
      records.map(\.path)
        == [
          "/v1/policy-canvases",
          "/v1/policy-canvases/create",
          "/v1/policy-canvases/duplicate",
          "/v1/policy-canvases/rename",
          "/v1/policy-canvases/active",
          "/v1/policy-canvases/delete",
        ]
    )
    #expect(records[0].query == nil)
    #expect(records[1].body?["title"] as? String == "Experiment A")
    #expect(records[2].body?["canvas_id"] as? String == "canvas-primary")
    #expect(records[2].body?["title"] as? String == "Experiment B")
    #expect(records[3].body?["canvas_id"] as? String == "canvas-primary")
    #expect(records[3].body?["title"] as? String == "Default")
    #expect(records[4].body?["canvas_id"] as? String == "canvas-experiment")
    #expect(records[5].body?["canvas_id"] as? String == "canvas-secondary")

    #expect(workspace.activeCanvasId == "canvas-primary")
    #expect(workspace.canvases.count == 2)
    #expect(created.activeCanvasId == "canvas-experiment")
    #expect(duplicated.canvases.last?.title == "Experiment B")
    #expect(renamed.canvases.first?.title == "Default")
    #expect(activated.activeCanvasId == "canvas-experiment")
    #expect(deleted.canvases.map(\.canvasId) == ["canvas-primary", "canvas-experiment"])
  }

  @Test("WebSocket transport uses policy-canvas library RPC contract")
  func webSocketTransportUsesPolicyCanvasLibraryRPCContract() async throws {
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

    let workspace = try await transport.policyCanvasWorkspace()
    let created = try await transport.createPolicyCanvas(
      request: PolicyCanvasCreateRequest(title: "Experiment A")
    )
    let duplicated = try await transport.duplicatePolicyCanvas(
      request: PolicyCanvasDuplicateRequest(
        canvasId: "canvas-primary",
        title: "Experiment B"
      )
    )
    let renamed = try await transport.renamePolicyCanvas(
      request: PolicyCanvasRenameRequest(
        canvasId: "canvas-primary",
        title: "Default"
      )
    )
    let activated = try await transport.activatePolicyCanvas(
      request: PolicyCanvasActivateRequest(canvasId: "canvas-experiment")
    )
    let deleted = try await transport.deletePolicyCanvas(
      request: PolicyCanvasDeleteRequest(canvasId: "canvas-secondary")
    )

    let calls = await probe.calls
    #expect(
      calls.map(\.method)
        == [
          .policyCanvasWorkspaceGet,
          .policyCanvasCreate,
          .policyCanvasDuplicate,
          .policyCanvasRename,
          .policyCanvasSetActive,
          .policyCanvasDelete,
        ]
    )
    #expect(calls[0].params == nil)
    #expect(policyObjectValue(calls[1].params, key: "title") == .string("Experiment A"))
    #expect(policyObjectValue(calls[2].params, key: "canvas_id") == .string("canvas-primary"))
    #expect(policyObjectValue(calls[2].params, key: "title") == .string("Experiment B"))
    #expect(policyObjectValue(calls[3].params, key: "canvas_id") == .string("canvas-primary"))
    #expect(policyObjectValue(calls[3].params, key: "title") == .string("Default"))
    #expect(policyObjectValue(calls[4].params, key: "canvas_id") == .string("canvas-experiment"))
    #expect(policyObjectValue(calls[5].params, key: "canvas_id") == .string("canvas-secondary"))

    #expect(workspace.activeCanvasId == "canvas-primary")
    #expect(created.activeCanvasId == "canvas-experiment")
    #expect(duplicated.canvases.last?.title == "Experiment B")
    #expect(renamed.canvases.first?.title == "Default")
    #expect(activated.activeCanvasId == "canvas-experiment")
    #expect(deleted.canvases.map(\.canvasId) == ["canvas-primary", "canvas-experiment"])
  }
}
