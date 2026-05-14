import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Task-board policy pipeline daemon API client", .serialized)
struct TaskBoardPolicyPipelineAPIClientTests {
  @Test("HTTP client uses policy-pipeline route contract")
  func httpClientUsesPolicyPipelineRoutes() async throws {
    TaskBoardURLProtocol.reset()
    let client = try makeClient()
    let document = sampleDraftDocument()

    let get = try await client.taskBoardPolicyPipeline()
    let save = try await client.saveTaskBoardPolicyPipelineDraft(
      request: TaskBoardPolicyPipelineSaveDraftRequest(document: document)
    )
    let simulation = try await client.simulateTaskBoardPolicyPipeline(
      request: TaskBoardPolicyPipelineSimulateRequest(document: document)
    )
    let promotion = try await client.promoteTaskBoardPolicyPipeline(
      request: TaskBoardPolicyPipelinePromoteRequest(revision: 7)
    )
    let audit = try await client.taskBoardPolicyPipelineAudit()

    let records = TaskBoardURLProtocol.records
    #expect(records.map(\.method) == ["GET", "PUT", "POST", "POST", "GET"])
    #expect(
      records.map(\.path)
        == [
          "/v1/task-board/policy/pipeline",
          "/v1/task-board/policy/pipeline",
          "/v1/task-board/policy/simulate",
          "/v1/task-board/policy/promote",
          "/v1/task-board/policy/audit",
        ]
    )
    #expect(records[0].query == nil)
    let savedDocument = records[1].body?["document"] as? [String: Any]
    #expect(savedDocument?["schema_version"] as? Int == 2)
    #expect(savedDocument?["revision"] as? Int == 7)
    #expect(savedDocument?["mode"] as? String == "draft")
    let savedNode = (savedDocument?["nodes"] as? [[String: Any]])?.first
    let savedEdge = (savedDocument?["edges"] as? [[String: Any]])?.first
    #expect(savedNode?["label"] as? String == "Ready for dispatch")
    #expect(savedEdge?["from_node"] as? String == "node-intake")
    let simulatedDocument = records[2].body?["document"] as? [String: Any]
    #expect(simulatedDocument?["revision"] as? Int == 7)
    #expect(records[3].body?["revision"] as? Int == 7)

    #expect(get.schemaVersion == 2)
    #expect(save.validation.isValid)
    #expect(simulation.decisions.first?.decision.decision == "allow")
    #expect(promotion.document.mode == .enforced)
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
    let document = sampleDraftDocument()

    let get = try await transport.taskBoardPolicyPipeline()
    let save = try await transport.saveTaskBoardPolicyPipelineDraft(
      request: TaskBoardPolicyPipelineSaveDraftRequest(document: document)
    )
    let simulation = try await transport.simulateTaskBoardPolicyPipeline(
      request: TaskBoardPolicyPipelineSimulateRequest(document: document)
    )
    let promotion = try await transport.promoteTaskBoardPolicyPipeline(
      request: TaskBoardPolicyPipelinePromoteRequest(revision: 7)
    )
    let audit = try await transport.taskBoardPolicyPipelineAudit()

    let calls = await probe.calls
    #expect(
      calls.map(\.method)
        == [
          .taskBoardPolicyPipelineGet,
          .taskBoardPolicyPipelineSaveDraft,
          .taskBoardPolicyPipelineSimulate,
          .taskBoardPolicyPipelinePromote,
          .taskBoardPolicyPipelineAudit,
        ]
    )
    #expect(calls[0].params == nil)
    if case .object(let document)? = objectValue(calls[1].params, key: "document") {
      #expect(document["schema_version"] == .number(2))
      #expect(document["revision"] == .number(7))
      #expect(document["mode"] == .string("draft"))
    } else {
      Issue.record("Expected document object in save draft params")
    }
    if case .object(let document)? = objectValue(calls[2].params, key: "document") {
      #expect(document["revision"] == .number(7))
    } else {
      Issue.record("Expected document object in simulate params")
    }
    #expect(objectValue(calls[3].params, key: "revision") == .number(7))
    #expect(calls[4].params == nil)

    #expect(get.revision == 7)
    #expect(save.document.nodes.count == 2)
    #expect(simulation.policyTraceIds == ["trace-policy-1"])
    #expect(promotion.traceId == "trace-policy-2")
    #expect(audit.mode == .draft)
  }

  @Test("Recording client implements policy-pipeline methods")
  func recordingClientImplementsPolicyPipelineMethods() async throws {
    let client = RecordingHarnessClient()
    let document = sampleDraftDocument()

    let get = try await client.taskBoardPolicyPipeline()
    _ = try await client.saveTaskBoardPolicyPipelineDraft(
      request: TaskBoardPolicyPipelineSaveDraftRequest(document: document)
    )
    let simulation = try await client.simulateTaskBoardPolicyPipeline(
      request: TaskBoardPolicyPipelineSimulateRequest(document: document)
    )
    let promotion = try await client.promoteTaskBoardPolicyPipeline(
      request: TaskBoardPolicyPipelinePromoteRequest(revision: 7)
    )
    let audit = try await client.taskBoardPolicyPipelineAudit()

    #expect(get.mode == .draft)
    #expect(simulation.traceId == "trace-policy-1")
    #expect(promotion.document.mode == .enforced)
    #expect(audit.latestTraceId == "trace-policy-1")
    #expect(client.readCallCount(.taskBoardPolicyPipeline) == 1)
    #expect(client.readCallCount(.taskBoardPolicyPipelineAudit) == 1)
    #expect(
      client.calls == [
        .saveTaskBoardPolicyPipelineDraft(revision: 7),
        .simulateTaskBoardPolicyPipeline,
        .promoteTaskBoardPolicyPipeline(revision: 7),
        .simulateTaskBoardPolicyPipeline,
      ]
    )
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

  private func sampleDraftDocument() -> TaskBoardPolicyPipelineDocument {
    TaskBoardPolicyPipelineDocument(
      schemaVersion: 2,
      revision: 7,
      mode: .draft,
      nodes: [
        TaskBoardPolicyPipelineNode(
          id: "node-intake",
          title: "Ready for dispatch",
          kind: TaskBoardPolicyPipelineNodeKind(
            kind: "action_gate",
            actions: [.spawnAgent]
          ),
          position: TaskBoardPolicyCanvasPoint(x: 20, y: 40),
          groupId: "group-dispatch",
          inputs: [TaskBoardPolicyPipelinePort(id: "in", title: "in")],
          outputs: [TaskBoardPolicyPipelinePort(id: "default", title: "default")]
        ),
        TaskBoardPolicyPipelineNode(
          id: "node-allow",
          title: "Allow spawn",
          kind: TaskBoardPolicyPipelineNodeKind(
            kind: "supervisor_rule",
            reasonCodes: ["default_allow"],
            decision: "allow"
          ),
          position: TaskBoardPolicyCanvasPoint(x: 280, y: 40),
          groupId: "group-dispatch",
          inputs: [TaskBoardPolicyPipelinePort(id: "in", title: "in")]
        ),
      ],
      edges: [
        TaskBoardPolicyPipelineEdge(
          id: "edge-intake-allow",
          fromNodeId: "node-intake",
          fromPort: "default",
          toNodeId: "node-allow",
          toPort: "in",
          condition: .always
        )
      ],
      groups: [
        TaskBoardPolicyPipelineGroup(
          id: "group-dispatch",
          title: "Dispatch",
          color: "#6aa8ff",
          frame: TaskBoardPolicyCanvasRect(x: 0, y: 0, width: 720, height: 180),
          nodeIds: ["node-intake", "node-allow"]
        )
      ],
      layout: TaskBoardPolicyPipelineLayout(
        nodes: [
          TaskBoardPolicyPipelineNodeLayout(nodeId: "node-intake", x: 20, y: 40),
          TaskBoardPolicyPipelineNodeLayout(nodeId: "node-allow", x: 280, y: 40),
        ]
      ),
      policyTraceIds: ["trace-policy-1"]
    )
  }
}
