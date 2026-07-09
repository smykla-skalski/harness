import Foundation
import HarnessMonitorPolicyModels
import Testing

@testable import HarnessMonitorKit

func makePolicyAPIClient() throws -> HarnessMonitorAPIClient {
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

func policyObjectValue(_ value: JSONValue?, key: String) -> JSONValue? {
  guard case .object(let object)? = value else {
    return nil
  }
  return object[key]
}

func samplePolicyDraftDocument() -> PolicyPipelineDocument {
  PolicyPipelineDocument(
    schemaVersion: 2,
    revision: 7,
    mode: .draft,
    nodes: [
      PolicyPipelineNode(
        id: "node-intake",
        title: "Ready for dispatch",
        kind: .actionGate(actions: [.spawnAgent]),
        automation: PolicyGraphAutomationBinding(
          eventSource: "clipboard",
          contentKinds: ["image"],
          actions: ["ocrImage"]
        ),
        position: PolicyCanvasPoint(x: 20, y: 40),
        groupId: "group-dispatch",
        inputs: [PolicyPipelinePort(id: "in", title: "in")],
        outputs: [PolicyPipelinePort(id: "default", title: "default")]
      ),
      PolicyPipelineNode(
        id: "node-allow",
        title: "Allow spawn",
        kind: .supervisorRule(decision: .allow, reasonCodes: [.defaultAllow]),
        position: PolicyCanvasPoint(x: 280, y: 40),
        groupId: "group-dispatch",
        inputs: [PolicyPipelinePort(id: "in", title: "in")]
      ),
    ],
    edges: [
      PolicyPipelineEdge(
        id: "edge-intake-allow",
        fromNodeId: "node-intake",
        fromPort: "default",
        toNodeId: "node-allow",
        toPort: "in",
        condition: .always
      )
    ],
    groups: [
      PolicyPipelineGroup(
        id: "group-dispatch",
        title: "Dispatch",
        color: "#6aa8ff",
        frame: PolicyCanvasRect(x: 0, y: 0, width: 720, height: 180),
        nodeIds: ["node-intake", "node-allow"]
      )
    ],
    layout: PolicyPipelineLayout(
      nodes: [
        PolicyPipelineNodeLayout(nodeId: "node-intake", x: 20, y: 40),
        PolicyPipelineNodeLayout(nodeId: "node-allow", x: 280, y: 40),
      ]
    ),
    policyTraceIds: ["trace-policy-1"]
  )
}
