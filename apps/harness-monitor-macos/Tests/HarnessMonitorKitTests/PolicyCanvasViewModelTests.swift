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
    #expect(viewModel.documentDirty)

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
    #expect(viewModel.documentDirty)
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

  @Test("zoom actions clamp and reset scale")
  func zoomActionsClampAndResetScale() {
    let viewModel = PolicyCanvasViewModel.sample()

    viewModel.setZoom(2)
    #expect(viewModel.zoom == 1.4)
    viewModel.setZoom(0.1)
    #expect(viewModel.zoom == 0.6)
    viewModel.resetZoom()
    #expect(viewModel.zoom == 1)
  }

  @Test("clean empty palette node deletes without confirmation")
  func cleanEmptyPaletteNodeDeletesWithoutConfirmation() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.createNode(kind: .condition, at: CGPoint(x: 120, y: 120))
    guard case .node(let nodeID) = viewModel.selection else {
      Issue.record("Expected created node selection")
      return
    }

    let request = viewModel.deleteSelectedComponent()

    #expect(request == nil)
    #expect(viewModel.node(nodeID) == nil)
  }

  @Test("connected node delete requires confirmation")
  func connectedNodeDeleteRequiresConfirmation() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.node("policy-source"))

    guard let request = viewModel.deleteSelectedComponent() else {
      Issue.record("Expected connected node deletion to require confirmation")
      return
    }
    #expect(viewModel.node("policy-source") != nil)
    #expect(request.confirmationTitle == "Delete Node")

    viewModel.confirmDelete(request)

    #expect(viewModel.node("policy-source") == nil)
    #expect(!viewModel.edges.contains { edge in edge.source.nodeID == "policy-source" })
  }

  @Test("group frame follows dragged member node")
  func groupFrameFollowsDraggedMemberNode() {
    let viewModel = PolicyCanvasViewModel.sample()
    let groupID = "group-evaluation"
    let beforeFrame = viewModel.group(groupID)?.frame ?? .zero

    viewModel.dragNode("risk-score", translation: CGSize(width: 0, height: 420))
    viewModel.endNodeDrag("risk-score", translation: CGSize(width: 0, height: 420))

    let node = viewModel.node("risk-score")
    let frame = viewModel.group(groupID)?.frame
    #expect(frame?.height ?? 0 > beforeFrame.height)
    #expect(
      frame?.contains(CGRect(origin: node?.position ?? .zero, size: PolicyCanvasLayout.nodeSize))
        == true
    )
  }

  @Test("inspector edits selected node edge and policy binding")
  func inspectorEditsSelectedNodeEdgeAndPolicyBinding() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: policyDocument(revision: 11), simulation: nil, audit: nil)

    viewModel.select(.node("node-intake"))
    viewModel.commitSelectedNodeTitle("Dispatch gate")
    viewModel.commitSelectedPolicyAction(.mergePr)
    viewModel.select(.edge("edge-intake-supervisor"))
    viewModel.commitSelectedEdgeLabel("approved policy")

    let exported = viewModel.exportDocument()
    let node = exported.nodes.first { $0.id == "node-intake" }
    let edge = exported.edges.first { $0.id == "edge-intake-supervisor" }

    #expect(node?.title == "Dispatch gate")
    #expect(node?.kind.actions == [.mergePr])
    #expect(edge?.label == "approved policy")
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

  @Test("loaded default graph starts with clear non-overlapping layout")
  func loadedDefaultGraphStartsWithClearNonOverlappingLayout() {
    let document = overlappingDefaultPolicyDocument(revision: 14)
    let viewModel = PolicyCanvasViewModel.sample()

    viewModel.load(document: document, simulation: nil, audit: nil)

    let groupFrames = Dictionary(uniqueKeysWithValues: viewModel.groups.map { ($0.id, $0.frame) })
    #expect(groupFrames["entry"]?.minX == PolicyCanvasLayout.initialContentOrigin.x)
    #expect(
      groupFrames.values.allSatisfy { frame in
        frame.minX >= PolicyCanvasLayout.initialContentOrigin.x
          && frame.minY >= PolicyCanvasLayout.initialContentOrigin.y
      }
    )
    #expect(!intersects(groupFrames["entry"], groupFrames["merge"]))
    #expect(!intersects(groupFrames["merge"], groupFrames["terminal"]))
    #expect(!intersects(groupFrames["entry"], groupFrames["terminal"]))
    #expect(!viewModel.nodesContainOverlaps)
    #expect(
      viewModel.nodes.allSatisfy { node in
        guard let groupID = node.groupID, let frame = groupFrames[groupID] else {
          return true
        }
        return frame.contains(CGRect(origin: node.position, size: PolicyCanvasLayout.nodeSize))
      }
    )
  }

  @Test("loaded default graph starts centered in large canvas space")
  func loadedDefaultGraphStartsCenteredInLargeCanvasSpace() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: PreviewFixtures.policyCanvasPipelineDocument(), simulation: nil, audit: nil)

    #expect(viewModel.initialViewportAnchorPoint.x == viewModel.canvasContentBounds.midX)
    #expect(viewModel.initialViewportAnchorPoint.y == viewModel.canvasContentBounds.midY)
    #expect(viewModel.canvasContentSize.width - viewModel.canvasContentBounds.maxX >= 1_000)
    #expect(viewModel.canvasContentSize.height - viewModel.canvasContentBounds.maxY >= 1_000)
  }

  @Test("generic policy edge labels are hidden")
  func genericPolicyEdgeLabelsAreHidden() {
    let edge = TaskBoardPolicyPipelineEdge(
      id: "edge-policy-label",
      fromNodeId: "source",
      fromPort: "policy",
      toNodeId: "target",
      toPort: "in",
      label: "policy"
    )

    #expect(policyCanvasEdge(edge).label.isEmpty)
  }

  @Test("tool rail spacing scales with font scale")
  func toolRailSpacingScalesWithFontScale() {
    let regular = PolicyCanvasToolRailMetrics(fontScale: 1)
    let larger = PolicyCanvasToolRailMetrics(fontScale: 1.5)

    #expect(larger.railWidth > regular.railWidth)
    #expect(larger.buttonWidth > regular.buttonWidth)
    #expect(larger.buttonHeight > regular.buttonHeight)
    #expect(larger.chipHorizontalPadding > regular.chipHorizontalPadding)
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
}
