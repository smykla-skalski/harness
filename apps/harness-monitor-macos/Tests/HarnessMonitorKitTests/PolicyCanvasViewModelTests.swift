import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas view model")
@MainActor
struct PolicyCanvasViewModelTests {
  @Test("node drag snaps and persists layout")
  func nodeDragSnapsAndPersistsLayout() {
    let viewModel = PolicyCanvasViewModel.sample()
    let nodeID = "risk-score"

    viewModel.dragNode(nodeID, translation: CGSize(width: 23, height: 17))
    viewModel.endNodeDrag(nodeID, translation: CGSize(width: 23, height: 17))

    let node = viewModel.node(nodeID)
    let x = node?.position.x ?? -1
    let y = node?.position.y ?? -1
    #expect(x.truncatingRemainder(dividingBy: PolicyCanvasLayout.gridSize) == 0)
    #expect(y.truncatingRemainder(dividingBy: PolicyCanvasLayout.gridSize) == 0)
    #expect(viewModel.isDirty)

    let exported = viewModel.exportDocument()
    let layout = exported.layout.nodes.first { $0.nodeId == nodeID }
    #expect(layout?.x == Int((node?.position.x ?? 0).rounded()))
    #expect(layout?.y == Int((node?.position.y ?? 0).rounded()))
  }

  @Test("palette drop creates a grouped node")
  func paletteDropCreatesGroupedNode() {
    let viewModel = PolicyCanvasViewModel.sample()
    let before = viewModel.nodes.count

    let created = viewModel.dropPalettePayloads(
      [viewModel.palettePayload(for: .review)],
      at: CGPoint(x: 100, y: 100)
    )

    #expect(created)
    #expect(viewModel.nodes.count == before + 1)
    #expect(viewModel.nodes.last?.groupID == "group-intake")
    #expect(viewModel.isDirty)
  }

  @Test("port drag creates valid edges and rejects self edges")
  func portDragCreatesValidEdgesAndRejectsSelfEdges() {
    let viewModel = PolicyCanvasViewModel.sample()
    let before = viewModel.edges.count

    let created = viewModel.connectDroppedPortPayloads(
      [viewModel.portDragPayload(nodeID: "policy-source", portID: "output-event")],
      targetNodeID: "review-gate",
      targetPortID: "input-policy"
    )
    let rejected = viewModel.connectDroppedPortPayloads(
      [viewModel.portDragPayload(nodeID: "risk-score", portID: "output-pass")],
      targetNodeID: "risk-score",
      targetPortID: "input-event"
    )

    #expect(created)
    #expect(!rejected)
    #expect(viewModel.edges.count == before + 1)
  }

  @Test("promote requires saved exact simulation")
  func promoteRequiresSavedExactSimulation() {
    let viewModel = PolicyCanvasViewModel.sample()
    let document = policyDocument(revision: 11)
    let simulation = TaskBoardPolicyPipelineSimulationResult(
      revision: 11,
      traceId: "trace-policy-11",
      simulatedAt: "2026-05-14T11:00:05Z",
      succeeded: true,
      validation: TaskBoardPolicyPipelineValidation(isValid: true)
    )

    viewModel.load(document: document, simulation: simulation, audit: nil)
    #expect(viewModel.canPromote)

    viewModel.createNode(kind: .condition, at: CGPoint(x: 100, y: 100))
    #expect(!viewModel.canPromote)
    #expect(viewModel.promoteDisabledReason == "Save draft changes first")
  }

  @Test("supervisor rule nodes map to policy overrides")
  func supervisorRuleNodesMapToPolicyOverrides() {
    let document = policyDocument(revision: 11)

    let overrides = document.supervisorPolicyOverrides()

    #expect(overrides.count == 1)
    #expect(overrides.first?.ruleID == "stuck-agent")
    #expect(overrides.first?.enabled == true)
    #expect(overrides.first?.parameters["policy_canvas_revision"] == "11")
  }

  @Test("loaded rich graph exports full node and edge semantics")
  func loadedRichGraphExportsFullNodeAndEdgeSemantics() {
    let document = richPolicyDocument(revision: 12)
    let viewModel = PolicyCanvasViewModel.sample()

    viewModel.load(document: document, simulation: nil, audit: nil)
    viewModel.dragNode("node-risk", translation: CGSize(width: 40, height: 0))
    viewModel.endNodeDrag("node-risk", translation: CGSize(width: 40, height: 0))

    let exported = viewModel.exportDocument()
    let riskKind = exported.nodes.first { $0.id == "node-risk" }?.kind
    let evidenceKind = exported.nodes.first { $0.id == "node-evidence" }?.kind
    let failureCondition = exported.edges.first { $0.id == "edge-evidence-risk-fail" }?.condition

    #expect(riskKind?.kind == "risk_classifier")
    #expect(riskKind?.field == .riskScore)
    #expect(riskKind?.threshold == 74)
    #expect(riskKind?.highRiskReasonCode == "merge_risk_high")
    #expect(riskKind?.missingReasonCode == "merge_risk_missing")
    #expect(evidenceKind?.kind == "evidence_check")
    #expect(evidenceKind?.checks.first?.field == .checksGreen)
    #expect(evidenceKind?.checks.first?.failReasonCode == "checks_not_green")
    #expect(failureCondition?.condition == "evidence_failure")
    #expect(failureCondition?.reasonCode == "checks_not_green")
  }

  @Test("validation issues preserve daemon fields")
  func validationIssuesPreserveDaemonFields() throws {
    let payload = Data(
      """
      {
        "issues": [
          {
            "issue": "unsupported_schema_version",
            "expected": 2,
            "actual": 9
          },
          {
            "issue": "invalid_port",
            "edge_id": "edge-missing",
            "node_id": "node-risk",
            "port": "missing",
            "direction": "input"
          },
          {
            "issue": "cycle",
            "node_ids": ["node-a", "node-b"]
          },
          {
            "issue": "duplicate_id",
            "id": "node-a",
            "location": "nodes"
          },
          {
            "issue": "unsafe_high_risk_action",
            "action": "merge_pr"
          }
        ]
      }
      """.utf8
    )

    let validation = try JSONDecoder().decode(TaskBoardPolicyPipelineValidation.self, from: payload)

    #expect(!validation.isValid)
    #expect(validation.issues[0].expected == 2)
    #expect(validation.issues[0].actual == 9)
    #expect(validation.issues[1].edgeId == "edge-missing")
    #expect(validation.issues[1].nodeId == "node-risk")
    #expect(validation.issues[1].port == "missing")
    #expect(validation.issues[1].direction == "input")
    #expect(validation.issues[2].nodeIds == ["node-a", "node-b"])
    #expect(validation.issues[3].id == "node-a")
    #expect(validation.issues[3].location == "nodes")
    #expect(validation.issues[4].action == .mergePr)
  }

  private func policyDocument(revision: UInt64) -> TaskBoardPolicyPipelineDocument {
    TaskBoardPolicyPipelineDocument(
      schemaVersion: 2,
      revision: revision,
      mode: .draft,
      nodes: [
        TaskBoardPolicyPipelineNode(
          id: "node-intake",
          title: "Ready for dispatch",
          kind: TaskBoardPolicyPipelineNodeKind(kind: "action_gate", actions: [.spawnAgent]),
          groupId: "group-dispatch",
          inputs: [TaskBoardPolicyPipelinePort(id: "in", title: "in")],
          outputs: [TaskBoardPolicyPipelinePort(id: "default", title: "default")]
        ),
        TaskBoardPolicyPipelineNode(
          id: "node-supervisor",
          title: "Stuck agent rule",
          kind: TaskBoardPolicyPipelineNodeKind(
            kind: "supervisor_rule",
            ruleId: "stuck-agent",
            reasonCodes: ["default_allow"],
            decision: "allow"
          ),
          groupId: "group-dispatch",
          inputs: [TaskBoardPolicyPipelinePort(id: "in", title: "in")]
        ),
      ],
      edges: [
        TaskBoardPolicyPipelineEdge(
          id: "edge-intake-supervisor",
          fromNodeId: "node-intake",
          fromPort: "default",
          toNodeId: "node-supervisor",
          toPort: "in"
        )
      ],
      groups: [
        TaskBoardPolicyPipelineGroup(
          id: "group-dispatch",
          title: "Dispatch",
          nodeIds: ["node-intake", "node-supervisor"]
        )
      ],
      layout: TaskBoardPolicyPipelineLayout(
        nodes: [
          TaskBoardPolicyPipelineNodeLayout(nodeId: "node-intake", x: 20, y: 40),
          TaskBoardPolicyPipelineNodeLayout(nodeId: "node-supervisor", x: 280, y: 40),
        ]
      ),
      policyTraceIds: ["trace-policy-11"]
    )
  }

  private func richPolicyDocument(revision: UInt64) -> TaskBoardPolicyPipelineDocument {
    TaskBoardPolicyPipelineDocument(
      schemaVersion: 2,
      revision: revision,
      mode: .draft,
      nodes: [
        TaskBoardPolicyPipelineNode(
          id: "node-evidence",
          title: "Check evidence",
          kind: TaskBoardPolicyPipelineNodeKind(
            kind: "evidence_check",
            checks: [
              TaskBoardPolicyEvidenceCheck(
                field: .checksGreen,
                pass: TaskBoardPolicyEvidencePredicate(predicate: "equals_true"),
                failReasonCode: "checks_not_green",
                missingReasonCode: "checks_missing"
              )
            ]
          ),
          groupId: "group-rich",
          inputs: [TaskBoardPolicyPipelinePort(id: "input-event", title: "event")],
          outputs: [
            TaskBoardPolicyPipelinePort(id: "output-pass", title: "pass"),
            TaskBoardPolicyPipelinePort(id: "output-fail", title: "fail"),
          ]
        ),
        TaskBoardPolicyPipelineNode(
          id: "node-risk",
          title: "Risk score",
          kind: TaskBoardPolicyPipelineNodeKind(
            kind: "risk_classifier",
            field: .riskScore,
            threshold: 74,
            highRiskReasonCode: "merge_risk_high",
            missingReasonCode: "merge_risk_missing"
          ),
          groupId: "group-rich",
          inputs: [TaskBoardPolicyPipelinePort(id: "input-event", title: "event")],
          outputs: [
            TaskBoardPolicyPipelinePort(id: "output-high", title: "high"),
            TaskBoardPolicyPipelinePort(id: "output-low", title: "low"),
          ]
        ),
      ],
      edges: [
        TaskBoardPolicyPipelineEdge(
          id: "edge-evidence-risk-fail",
          fromNodeId: "node-evidence",
          fromPort: "output-fail",
          toNodeId: "node-risk",
          toPort: "input-event",
          condition: TaskBoardPolicyPipelineEdgeCondition(
            condition: "evidence_failure",
            reasonCode: "checks_not_green"
          )
        )
      ],
      groups: [
        TaskBoardPolicyPipelineGroup(
          id: "group-rich",
          title: "Rich policy",
          nodeIds: ["node-evidence", "node-risk"]
        )
      ],
      layout: TaskBoardPolicyPipelineLayout(
        nodes: [
          TaskBoardPolicyPipelineNodeLayout(nodeId: "node-evidence", x: 20, y: 40),
          TaskBoardPolicyPipelineNodeLayout(nodeId: "node-risk", x: 300, y: 40),
        ]
      ),
      policyTraceIds: ["trace-rich-policy"]
    )
  }
}
