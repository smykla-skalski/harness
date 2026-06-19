import Foundation
import HarnessMonitorPolicyModels
import Testing

@testable import HarnessMonitorKit

/// Wire-contract regression for the policy simulate/audit cluster generated from
/// src/task_board/policy_graph/store.rs. These *Wire types own the daemon's
/// snake_case shape (explicit CodingKeys, plain decoder) and their validation
/// report nests the generated PolicyGraphValidationIssue. This pins the fix for
/// the real bug where node_id/edge_id/node_ids silently vanished: simulate+audit
/// decoded through the default convertFromSnakeCase decoder, which rewrote the
/// daemon's node_id to nodeId before matching the literal node_id CodingKey, so
/// those fields dropped. Decoded through PolicyWireCoding.decoder (no key
/// strategy) the tagged-enum issues carry their identifiers faithfully.
@Suite("Policy pipeline simulation wire decoding")
struct PolicyPipelineSimulationWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("simulation result decodes validation issues keeping node/edge ids")
  func decodesSimulationValidationIssues() throws {
    let json = #"""
      {"revision":3,"trace_id":"trace-1","simulated_at":"2026-06-17T00:00:00Z","succeeded":false,"validation":{"issues":[{"issue":"dangling_edge","edge_id":"e-1","node_id":"n-1"},{"issue":"cycle","node_ids":["n-2","n-3"]},{"issue":"invalid_port","edge_id":"e-2","node_id":"n-4","port":"in","direction":"input"}]},"policy_trace_ids":["t-1"],"has_runtime_boundaries":true}
      """#
    let result = try decoder.decode(
      PolicyPipelineSimulationResultWire.self,
      from: Data(json.utf8)
    )

    #expect(result.traceId == "trace-1")
    #expect(result.hasRuntimeBoundaries == true)
    #expect(result.decisions.isEmpty)
    #expect(result.validation.issues.count == 3)

    guard case .danglingEdge(let edgeId, let nodeId) = result.validation.issues[0] else {
      Issue.record("expected dangling_edge, got \(result.validation.issues[0])")
      return
    }
    #expect(edgeId == "e-1")
    #expect(nodeId == "n-1")

    guard case .cycle(let nodeIds) = result.validation.issues[1] else {
      Issue.record("expected cycle, got \(result.validation.issues[1])")
      return
    }
    #expect(nodeIds == ["n-2", "n-3"])

    guard
      case .invalidPort(let portEdgeId, let portNodeId, let port, let direction) =
        result.validation.issues[2]
    else {
      Issue.record("expected invalid_port, got \(result.validation.issues[2])")
      return
    }
    #expect(portEdgeId == "e-2")
    #expect(portNodeId == "n-4")
    #expect(port == "in")
    #expect(direction == .input)
  }

  @Test("audit summary decodes its nested validation and latest simulation")
  func decodesAuditSummary() throws {
    let json = #"""
      {"active_revision":7,"mode":"enforced","latest_trace_id":"trace-9","latest_simulation":{"revision":7,"trace_id":"trace-9","simulated_at":"2026-06-17T00:00:00Z","succeeded":true,"validation":{"issues":[]}},"validation":{"issues":[{"issue":"incompatible_payload_edge","edge_id":"e-3","provided":"json","required":"text"}]}}
      """#
    let summary = try decoder.decode(
      PolicyPipelineAuditSummaryWire.self,
      from: Data(json.utf8)
    )

    #expect(summary.activeRevision == 7)
    #expect(summary.latestTraceId == "trace-9")
    #expect(summary.latestSimulation?.traceId == "trace-9")
    #expect(summary.validation.issues.count == 1)

    guard
      case .incompatiblePayloadEdge(let edgeId, let provided, let required) =
        summary.validation.issues[0]
    else {
      Issue.record("expected incompatible_payload_edge, got \(summary.validation.issues[0])")
      return
    }
    #expect(edgeId == "e-3")
    #expect(provided == "json")
    #expect(required == "text")
  }

  @Test("simulation result maps to the flat app model keeping issue ids")
  func mapsSimulationResultToAppModel() throws {
    // This is the end-to-end regression: decode the daemon payload through the
    // wire type (plain decoder) then map to the flat app model the validation
    // panel consumes. Before the fix, simulate decoded via convertFromSnakeCase
    // and node_id/edge_id/node_ids dropped to nil/[]; here they survive.
    let json = #"""
      {"revision":4,"trace_id":"trace-2","simulated_at":"2026-06-17T00:00:00Z","succeeded":false,"validation":{"issues":[{"issue":"dangling_edge","edge_id":"e-9","node_id":"n-9"},{"issue":"cycle","node_ids":["a","b"]}]},"decisions":[{"action":"merge_pr","decision":{"decision":"deny","reason_code":"checks_not_green","policy_version":"v1"},"visited_node_ids":["n-9"],"policy_trace_ids":["t-2"]}],"policy_trace_ids":["t-2"],"has_runtime_boundaries":false}
      """#
    let wire = try decoder.decode(
      PolicyPipelineSimulationResultWire.self,
      from: Data(json.utf8)
    )
    let model = TaskBoardPolicyPipelineSimulationResult(wire: wire)

    #expect(model.traceId == "trace-2")
    #expect(model.validation.isValid == false)
    #expect(model.validation.issues.count == 2)

    let dangling = model.validation.issues[0]
    #expect(dangling.code == "dangling_edge")
    #expect(dangling.edgeId == "e-9")
    #expect(dangling.nodeId == "n-9")
    #expect(dangling.message == "Dangling edge e-9 references node n-9")

    let cycle = model.validation.issues[1]
    #expect(cycle.code == "cycle")
    #expect(cycle.nodeIds == ["a", "b"])

    #expect(model.decisions.count == 1)
    #expect(model.decisions[0].action == .mergePr)
    #expect(model.decisions[0].decision.decision == "deny")
    #expect(model.decisions[0].decision.reasonCode == "checks_not_green")
  }
}
