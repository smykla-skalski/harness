import Foundation
import HarnessMonitorPolicyModels
import Testing

@testable import HarnessMonitorKit

@Suite("Policy pipeline daemon API client", .serialized)
struct PolicyPipelineAPIClientTests {
  @Test("HTTP client uses policy-pipeline route contract")
  func httpClientUsesPolicyPipelineRoutes() async throws {
    TaskBoardURLProtocol.reset()
    let client = try makePolicyAPIClient()
    let document = samplePolicyDraftDocument()

    let get = try await client.policyPipeline(canvasId: "canvas-primary")
    let save = try await client.savePolicyPipelineDraft(
      request: PolicyPipelineSaveDraftRequest(
        canvasId: "canvas-primary",
        document: document
      )
    )
    let simulation = try await client.simulatePolicyPipeline(
      request: PolicyPipelineSimulateRequest(
        canvasId: "canvas-primary",
        document: document
      )
    )
    let promotion = try await client.promotePolicyPipeline(
      request: PolicyPipelinePromoteRequest(canvasId: "canvas-primary", revision: 7)
    )
    let makeLive = try await client.makeLivePolicyPipeline(
      request: PolicyPipelineMakeLiveRequest(canvasId: "canvas-primary", revision: 7)
    )
    let goLiveDiff = try await client.goLiveDiffPolicyPipeline(
      request: PolicyPipelineGoLiveDiffRequest(canvasId: "canvas-primary")
    )
    let replay = try await client.replayPolicyPipeline(
      request: PolicyPipelineReplayRequest(canvasId: "canvas-primary", limit: 25)
    )
    let audit = try await client.policyPipelineAudit(canvasId: "canvas-primary")

    let records = TaskBoardURLProtocol.records
    #expect(records.map(\.method) == ["GET", "PUT", "POST", "POST", "POST", "POST", "POST", "GET"])
    #expect(
      records.map(\.path)
        == [
          "/v1/policy-pipeline",
          "/v1/policy-pipeline",
          "/v1/policy-pipeline/simulate",
          "/v1/policy-pipeline/promote",
          "/v1/policy-pipeline/make-live",
          "/v1/policy-pipeline/go-live-diff",
          "/v1/policy-pipeline/replay",
          "/v1/policy-pipeline/audit",
        ]
    )
    #expect(records[0].query == "canvas_id=canvas-primary")
    let savedDocument = records[1].body?["document"] as? [String: Any]
    #expect(records[1].body?["canvas_id"] as? String == "canvas-primary")
    #expect(records[1].body?["if_revision"] as? Int == 7)
    #expect(savedDocument?["schema_version"] as? Int == 2)
    #expect(savedDocument?["revision"] as? Int == 7)
    #expect(savedDocument?["mode"] as? String == "draft")
    let savedNode = (savedDocument?["nodes"] as? [[String: Any]])?.first
    let savedEdge = (savedDocument?["edges"] as? [[String: Any]])?.first
    #expect(savedNode?["label"] as? String == "Ready for dispatch")
    let savedAutomation = savedNode?["automation"] as? [String: Any]
    #expect(savedAutomation?["event_source"] as? String == "clipboard")
    #expect(savedAutomation?["content_kinds"] as? [String] == ["image"])
    #expect(savedEdge?["from_node"] as? String == "node-intake")
    let simulatedDocument = records[2].body?["document"] as? [String: Any]
    #expect(records[2].body?["canvas_id"] as? String == "canvas-primary")
    #expect(simulatedDocument?["revision"] as? Int == 7)
    #expect(records[3].body?["canvas_id"] as? String == "canvas-primary")
    #expect(records[3].body?["revision"] as? Int == 7)
    #expect(records[4].body?["canvas_id"] as? String == "canvas-primary")
    #expect(records[4].body?["revision"] as? Int == 7)
    #expect(records[5].body?["canvas_id"] as? String == "canvas-primary")
    #expect(records[6].body?["canvas_id"] as? String == "canvas-primary")
    #expect(records[6].body?["limit"] as? Int == 25)
    #expect(records[7].query == "canvas_id=canvas-primary")

    #expect(get.schemaVersion == 2)
    #expect(save.validation.isValid)
    #expect(simulation.decisions.first?.decision.decision == "allow")
    #expect(simulation.decisions.first?.visitedNodeIds.isEmpty == true)
    #expect(promotion.document.mode == .enforced)
    #expect(makeLive.globalPolicyEnforcementEnabled)
    #expect(makeLive.workspace.activeCanvasId == "canvas-primary")
    #expect(goLiveDiff.changedCount == 0)
    #expect(replay.sampleSize == 2)
    #expect(audit.latestTraceId == "trace-policy-1")
  }

  @Test("WebSocket transport uses policy-pipeline RPC contract")
  func webSocketTransportUsesPolicyPipelineRPCContract() async throws {
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
    let document = samplePolicyDraftDocument()

    let get = try await transport.policyPipeline(canvasId: "canvas-primary")
    let save = try await transport.savePolicyPipelineDraft(
      request: PolicyPipelineSaveDraftRequest(
        canvasId: "canvas-primary",
        document: document
      )
    )
    let simulation = try await transport.simulatePolicyPipeline(
      request: PolicyPipelineSimulateRequest(
        canvasId: "canvas-primary",
        document: document
      )
    )
    let promotion = try await transport.promotePolicyPipeline(
      request: PolicyPipelinePromoteRequest(canvasId: "canvas-primary", revision: 7)
    )
    let makeLive = try await transport.makeLivePolicyPipeline(
      request: PolicyPipelineMakeLiveRequest(canvasId: "canvas-primary", revision: 7)
    )
    let goLiveDiff = try await transport.goLiveDiffPolicyPipeline(
      request: PolicyPipelineGoLiveDiffRequest(canvasId: "canvas-primary")
    )
    let replay = try await transport.replayPolicyPipeline(
      request: PolicyPipelineReplayRequest(canvasId: "canvas-primary", limit: 25)
    )
    let audit = try await transport.policyPipelineAudit(canvasId: "canvas-primary")

    let calls = await probe.calls
    assertPolicyPipelineRPCMethods(calls)
    assertPolicyPipelineSaveDraftRPCParams(calls[1].params)
    assertPolicyPipelineSimulateRPCParams(calls[2].params)
    assertPolicyPipelineActionRPCParams(calls)

    #expect(get.revision == 7)
    #expect(save.document.nodes.count == 2)
    #expect(simulation.policyTraceIds == ["trace-policy-1"])
    #expect(simulation.decisions.first?.visitedNodeIds.isEmpty == true)
    #expect(promotion.traceId == "trace-policy-2")
    #expect(makeLive.globalPolicyEnforcementEnabled)
    #expect(makeLive.workspace.activeCanvasId == "canvas-primary")
    #expect(goLiveDiff.changedCount == 0)
    #expect(replay.sampleSize == 2)
    #expect(audit.mode == .draft)
  }

  @Test("Recording client implements policy-pipeline methods")
  func recordingClientImplementsPolicyPipelineMethods() async throws {
    let client = RecordingHarnessClient()
    let document = samplePolicyDraftDocument()

    let get = try await client.policyPipeline(canvasId: "canvas-primary")
    _ = try await client.savePolicyPipelineDraft(
      request: PolicyPipelineSaveDraftRequest(
        canvasId: "canvas-primary",
        document: document
      )
    )
    let simulation = try await client.simulatePolicyPipeline(
      request: PolicyPipelineSimulateRequest(
        canvasId: "canvas-primary",
        document: document
      )
    )
    let promotion = try await client.promotePolicyPipeline(
      request: PolicyPipelinePromoteRequest(canvasId: "canvas-primary", revision: 7)
    )
    let audit = try await client.policyPipelineAudit(canvasId: "canvas-primary")

    #expect(get.mode == .draft)
    #expect(simulation.traceId == "trace-policy-1")
    #expect(promotion.document.mode == .enforced)
    #expect(audit.latestTraceId == "trace-policy-1")
    #expect(client.readCallCount(.policyPipeline) == 1)
    #expect(client.readCallCount(.policyPipelineAudit) == 1)
    #expect(
      client.calls == [
        .savePolicyPipelineDraft(revision: 7),
        .simulatePolicyPipeline,
        .promotePolicyPipeline(revision: 7),
        .simulatePolicyPipeline,
      ]
    )
  }
}

private func assertPolicyPipelineRPCMethods(_ calls: [RPCProbe.Call]) {
  #expect(
    calls.map(\.method)
      == [
        .policyPipelineGet,
        .policyPipelineSaveDraft,
        .policyPipelineSimulate,
        .policyPipelinePromote,
        .policyPipelineMakeLive,
        .policyPipelineGoLiveDiff,
        .policyPipelineReplay,
        .policyPipelineAudit,
      ]
  )
}

private func assertPolicyPipelineSaveDraftRPCParams(_ params: JSONValue?) {
  #expect(policyObjectValue(params, key: "canvas_id") == .string("canvas-primary"))
  #expect(policyObjectValue(params, key: "if_revision") == .number(7))
  guard case .object(let document)? = policyObjectValue(params, key: "document") else {
    Issue.record("Expected document object in save draft params")
    return
  }
  #expect(document["schema_version"] == .number(2))
  #expect(document["revision"] == .number(7))
  #expect(document["mode"] == .string("draft"))
  guard case .array(let nodes)? = document["nodes"],
    case .object(let firstNode)? = nodes.first,
    case .object(let automation)? = firstNode["automation"]
  else {
    Issue.record("Expected automation object in save draft document")
    return
  }
  #expect(automation["event_source"] == .string("clipboard"))
  #expect(automation["actions"] == .array([.string("ocrImage")]))
}

private func assertPolicyPipelineSimulateRPCParams(_ params: JSONValue?) {
  #expect(policyObjectValue(params, key: "canvas_id") == .string("canvas-primary"))
  guard case .object(let document)? = policyObjectValue(params, key: "document") else {
    Issue.record("Expected document object in simulate params")
    return
  }
  #expect(document["revision"] == .number(7))
}

private func assertPolicyPipelineActionRPCParams(_ calls: [RPCProbe.Call]) {
  #expect(calls[0].params == .object(["canvas_id": .string("canvas-primary")]))
  #expect(policyObjectValue(calls[3].params, key: "canvas_id") == .string("canvas-primary"))
  #expect(policyObjectValue(calls[3].params, key: "revision") == .number(7))
  #expect(policyObjectValue(calls[4].params, key: "canvas_id") == .string("canvas-primary"))
  #expect(policyObjectValue(calls[4].params, key: "revision") == .number(7))
  #expect(calls[5].params == .object(["canvas_id": .string("canvas-primary")]))
  #expect(policyObjectValue(calls[6].params, key: "canvas_id") == .string("canvas-primary"))
  #expect(policyObjectValue(calls[6].params, key: "limit") == .number(25))
  #expect(calls[7].params == .object(["canvas_id": .string("canvas-primary")]))
}
