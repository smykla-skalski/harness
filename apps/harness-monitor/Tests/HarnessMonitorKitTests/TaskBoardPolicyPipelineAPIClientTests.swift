import Foundation
import HarnessMonitorPolicyModels
import Testing

@testable import HarnessMonitorKit

@Suite("Task-board policy pipeline daemon API client", .serialized)
struct TaskBoardPolicyPipelineAPIClientTests {
  @Test("HTTP client uses policy-pipeline route contract")
  func httpClientUsesPolicyPipelineRoutes() async throws {
    TaskBoardURLProtocol.reset()
    let client = try makeClient()
    let document = sampleDraftDocument()

    let get = try await client.taskBoardPolicyPipeline(canvasId: "canvas-primary")
    let save = try await client.saveTaskBoardPolicyPipelineDraft(
      request: TaskBoardPolicyPipelineSaveDraftRequest(
        canvasId: "canvas-primary",
        document: document
      )
    )
    let simulation = try await client.simulateTaskBoardPolicyPipeline(
      request: TaskBoardPolicyPipelineSimulateRequest(
        canvasId: "canvas-primary",
        document: document
      )
    )
    let promotion = try await client.promoteTaskBoardPolicyPipeline(
      request: TaskBoardPolicyPipelinePromoteRequest(canvasId: "canvas-primary", revision: 7)
    )
    let audit = try await client.taskBoardPolicyPipelineAudit(canvasId: "canvas-primary")

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
    #expect(records[4].query == "canvas_id=canvas-primary")

    #expect(get.schemaVersion == 2)
    #expect(save.validation.isValid)
    #expect(simulation.decisions.first?.decision.decision == "allow")
    #expect(simulation.decisions.first?.visitedNodeIds.isEmpty == true)
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

    let get = try await transport.taskBoardPolicyPipeline(canvasId: "canvas-primary")
    let save = try await transport.saveTaskBoardPolicyPipelineDraft(
      request: TaskBoardPolicyPipelineSaveDraftRequest(
        canvasId: "canvas-primary",
        document: document
      )
    )
    let simulation = try await transport.simulateTaskBoardPolicyPipeline(
      request: TaskBoardPolicyPipelineSimulateRequest(
        canvasId: "canvas-primary",
        document: document
      )
    )
    let promotion = try await transport.promoteTaskBoardPolicyPipeline(
      request: TaskBoardPolicyPipelinePromoteRequest(canvasId: "canvas-primary", revision: 7)
    )
    let audit = try await transport.taskBoardPolicyPipelineAudit(canvasId: "canvas-primary")

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
    #expect(calls[0].params == .object(["canvas_id": .string("canvas-primary")]))
    if case .object(let document)? = objectValue(calls[1].params, key: "document") {
      #expect(document["schema_version"] == .number(2))
      #expect(document["revision"] == .number(7))
      #expect(document["mode"] == .string("draft"))
      if case .array(let nodes)? = document["nodes"],
        case .object(let firstNode)? = nodes.first,
        case .object(let automation)? = firstNode["automation"]
      {
        #expect(automation["event_source"] == .string("clipboard"))
        #expect(automation["actions"] == .array([.string("ocrImage")]))
      } else {
        Issue.record("Expected automation object in save draft document")
      }
    } else {
      Issue.record("Expected document object in save draft params")
    }
    #expect(objectValue(calls[1].params, key: "canvas_id") == .string("canvas-primary"))
    #expect(objectValue(calls[1].params, key: "if_revision") == .number(7))
    if case .object(let document)? = objectValue(calls[2].params, key: "document") {
      #expect(document["revision"] == .number(7))
    } else {
      Issue.record("Expected document object in simulate params")
    }
    #expect(objectValue(calls[2].params, key: "canvas_id") == .string("canvas-primary"))
    #expect(objectValue(calls[3].params, key: "canvas_id") == .string("canvas-primary"))
    #expect(objectValue(calls[3].params, key: "revision") == .number(7))
    #expect(calls[4].params == .object(["canvas_id": .string("canvas-primary")]))

    #expect(get.revision == 7)
    #expect(save.document.nodes.count == 2)
    #expect(simulation.policyTraceIds == ["trace-policy-1"])
    #expect(simulation.decisions.first?.visitedNodeIds.isEmpty == true)
    #expect(promotion.traceId == "trace-policy-2")
    #expect(audit.mode == .draft)
  }

  @Test("Recording client implements policy-pipeline methods")
  func recordingClientImplementsPolicyPipelineMethods() async throws {
    let client = RecordingHarnessClient()
    let document = sampleDraftDocument()

    let get = try await client.taskBoardPolicyPipeline(canvasId: "canvas-primary")
    _ = try await client.saveTaskBoardPolicyPipelineDraft(
      request: TaskBoardPolicyPipelineSaveDraftRequest(
        canvasId: "canvas-primary",
        document: document
      )
    )
    let simulation = try await client.simulateTaskBoardPolicyPipeline(
      request: TaskBoardPolicyPipelineSimulateRequest(
        canvasId: "canvas-primary",
        document: document
      )
    )
    let promotion = try await client.promoteTaskBoardPolicyPipeline(
      request: TaskBoardPolicyPipelinePromoteRequest(canvasId: "canvas-primary", revision: 7)
    )
    let audit = try await client.taskBoardPolicyPipelineAudit(canvasId: "canvas-primary")

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

  @Test("HTTP client uses policy-canvas library route contract")
  func httpClientUsesPolicyCanvasLibraryRoutes() async throws {
    TaskBoardURLProtocol.reset()
    let client = try makeClient()

    let workspace = try await client.taskBoardPolicyCanvasWorkspace()
    let created = try await client.createTaskBoardPolicyCanvas(
      request: TaskBoardPolicyCanvasCreateRequest(title: "Experiment A")
    )
    let duplicated = try await client.duplicateTaskBoardPolicyCanvas(
      request: TaskBoardPolicyCanvasDuplicateRequest(
        canvasId: "canvas-primary",
        title: "Experiment B"
      )
    )
    let renamed = try await client.renameTaskBoardPolicyCanvas(
      request: TaskBoardPolicyCanvasRenameRequest(
        canvasId: "canvas-primary",
        title: "Default"
      )
    )
    let activated = try await client.activateTaskBoardPolicyCanvas(
      request: TaskBoardPolicyCanvasActivateRequest(canvasId: "canvas-experiment")
    )
    let deleted = try await client.deleteTaskBoardPolicyCanvas(
      request: TaskBoardPolicyCanvasDeleteRequest(canvasId: "canvas-secondary")
    )

    let records = TaskBoardURLProtocol.records
    #expect(records.map(\.method) == ["GET", "POST", "POST", "POST", "POST", "POST"])
    #expect(
      records.map(\.path)
        == [
          "/v1/task-board/policy/canvases",
          "/v1/task-board/policy/canvases/create",
          "/v1/task-board/policy/canvases/duplicate",
          "/v1/task-board/policy/canvases/rename",
          "/v1/task-board/policy/canvases/active",
          "/v1/task-board/policy/canvases/delete",
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

    let workspace = try await transport.taskBoardPolicyCanvasWorkspace()
    let created = try await transport.createTaskBoardPolicyCanvas(
      request: TaskBoardPolicyCanvasCreateRequest(title: "Experiment A")
    )
    let duplicated = try await transport.duplicateTaskBoardPolicyCanvas(
      request: TaskBoardPolicyCanvasDuplicateRequest(
        canvasId: "canvas-primary",
        title: "Experiment B"
      )
    )
    let renamed = try await transport.renameTaskBoardPolicyCanvas(
      request: TaskBoardPolicyCanvasRenameRequest(
        canvasId: "canvas-primary",
        title: "Default"
      )
    )
    let activated = try await transport.activateTaskBoardPolicyCanvas(
      request: TaskBoardPolicyCanvasActivateRequest(canvasId: "canvas-experiment")
    )
    let deleted = try await transport.deleteTaskBoardPolicyCanvas(
      request: TaskBoardPolicyCanvasDeleteRequest(canvasId: "canvas-secondary")
    )

    let calls = await probe.calls
    #expect(
      calls.map(\.method)
        == [
          .taskBoardPolicyCanvasWorkspaceGet,
          .taskBoardPolicyCanvasCreate,
          .taskBoardPolicyCanvasDuplicate,
          .taskBoardPolicyCanvasRename,
          .taskBoardPolicyCanvasSetActive,
          .taskBoardPolicyCanvasDelete,
        ]
    )
    #expect(calls[0].params == nil)
    #expect(objectValue(calls[1].params, key: "title") == .string("Experiment A"))
    #expect(objectValue(calls[2].params, key: "canvas_id") == .string("canvas-primary"))
    #expect(objectValue(calls[2].params, key: "title") == .string("Experiment B"))
    #expect(objectValue(calls[3].params, key: "canvas_id") == .string("canvas-primary"))
    #expect(objectValue(calls[3].params, key: "title") == .string("Default"))
    #expect(objectValue(calls[4].params, key: "canvas_id") == .string("canvas-experiment"))
    #expect(objectValue(calls[5].params, key: "canvas_id") == .string("canvas-secondary"))

    #expect(workspace.activeCanvasId == "canvas-primary")
    #expect(created.activeCanvasId == "canvas-experiment")
    #expect(duplicated.canvases.last?.title == "Experiment B")
    #expect(renamed.canvases.first?.title == "Default")
    #expect(activated.activeCanvasId == "canvas-experiment")
    #expect(deleted.canvases.map(\.canvasId) == ["canvas-primary", "canvas-experiment"])
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
          kind: .actionGate(actions: [.spawnAgent]),
          automation: PolicyGraphAutomationBinding(
            eventSource: "clipboard",
            contentKinds: ["image"],
            actions: ["ocrImage"]
          ),
          position: TaskBoardPolicyCanvasPoint(x: 20, y: 40),
          groupId: "group-dispatch",
          inputs: [TaskBoardPolicyPipelinePort(id: "in", title: "in")],
          outputs: [TaskBoardPolicyPipelinePort(id: "default", title: "default")]
        ),
        TaskBoardPolicyPipelineNode(
          id: "node-allow",
          title: "Allow spawn",
          kind: .supervisorRule(decision: .allow, reasonCodes: [.defaultAllow]),
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
