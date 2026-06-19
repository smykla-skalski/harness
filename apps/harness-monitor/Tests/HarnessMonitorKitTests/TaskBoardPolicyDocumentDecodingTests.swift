import Foundation
import HarnessMonitorPolicyModels
import Testing

@testable import HarnessMonitorKit

/// Pins the snake_case decode contract for the policy document. The daemon emits
/// uniform snake_case (`from_node`, `reason_codes`, `high_risk_reason_code`), and
/// the generated node-kind payloads carry explicit snake coding keys, so the whole
/// document subtree must decode with `PolicyWireCoding.decoder` (no key strategy).
/// Decoding it with `.convertFromSnakeCase` drops the generated keys and throws -
/// the regression this guards against.
@Suite("Policy document snake_case decoding")
struct TaskBoardPolicyDocumentDecodingTests {
  private static let snakeDocument = """
    {
      "schema_version": 2,
      "revision": 7,
      "mode": "draft",
      "nodes": [
        {
          "id": "supervisor:allow",
          "label": "allow",
          "kind": {
            "kind": "supervisor_rule",
            "decision": "allow",
            "reason_codes": ["default_allow"]
          },
          "input_ports": ["in"],
          "output_ports": [],
          "group_id": "terminal"
        },
        {
          "id": "risk:merge",
          "label": "Merge risk",
          "kind": {
            "kind": "risk_classifier",
            "field": "risk_score",
            "threshold": 40,
            "high_risk_reason_code": "risk_above_threshold",
            "missing_reason_code": "missing_merge_evidence"
          },
          "input_ports": ["in"],
          "output_ports": ["low_or_equal", "high", "missing"],
          "group_id": "merge"
        }
      ],
      "edges": [
        {
          "id": "edge:risk-high",
          "from_node": "risk:merge",
          "from_port": "high",
          "to_node": "supervisor:allow",
          "to_port": "in",
          "condition": { "condition": "risk_high" },
          "label": "high risk"
        }
      ],
      "groups": [
        {
          "id": "terminal",
          "label": "Terminal decisions",
          "color": "#72d989",
          "frame": { "x": 10, "y": 20, "width": 256, "height": 200 },
          "node_ids": ["supervisor:allow"]
        }
      ],
      "layout": {
        "zoom": 1,
        "offset": { "x": 0, "y": 0 },
        "nodes": [{ "node_id": "risk:merge", "x": 1240, "y": 1260 }]
      },
      "policy_trace_ids": ["task-board-policy-graph-v2"]
    }
    """

  @Test("decodes the daemon's snake_case wire end to end")
  func decodesSnakeWire() throws {
    let data = Data(Self.snakeDocument.utf8)
    let document = try PolicyWireCoding.decoder.decode(
      TaskBoardPolicyPipelineDocument.self,
      from: data
    )

    #expect(document.schemaVersion == 2)
    #expect(document.revision == 7)
    #expect(document.nodes.count == 2)
    #expect(document.policyTraceIds == ["task-board-policy-graph-v2"])

    let supervisor = document.nodes.first { $0.id == "supervisor:allow" }
    guard case .supervisorRule(let decision, let reasonCodes) = supervisor?.kind else {
      Issue.record("supervisor node did not decode as .supervisorRule")
      return
    }
    #expect(decision == .allow)
    #expect(reasonCodes == [.defaultAllow])

    let risk = document.nodes.first { $0.id == "risk:merge" }
    guard
      case .riskClassifier(let field, let threshold, let highRisk, let missing) = risk?.kind
    else {
      Issue.record("risk node did not decode as .riskClassifier")
      return
    }
    #expect(field == .riskScore)
    #expect(threshold == 40)
    #expect(highRisk == .riskAboveThreshold)
    #expect(missing == .missingMergeEvidence)

    #expect(document.edges.first?.fromNodeId == "risk:merge")
    #expect(document.edges.first?.toNodeId == "supervisor:allow")
    #expect(document.groups.first?.nodeIds == ["supervisor:allow"])
    #expect(document.layout.nodes.first?.nodeId == "risk:merge")
    #expect(document.nodes.first { $0.id == "supervisor:allow" }?.groupId == "terminal")
  }
}
