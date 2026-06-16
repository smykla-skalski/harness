import Foundation
import HarnessMonitorPolicyModels
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

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
    #expect(viewModel.zoom == PolicyCanvasLayout.minimumZoom)
    viewModel.resetZoom()
    #expect(viewModel.zoom == 1)
  }

  @Test("empty canvas content size stays finite at higher zoom levels")
  func emptyCanvasContentSizeStaysFiniteAtHigherZoomLevels() {
    let viewModel = PolicyCanvasViewModel(nodes: [], groups: [], edges: [])

    viewModel.setZoom(PolicyCanvasLayout.maximumZoom)

    #expect(viewModel.canvasContentBounds.isNull)
    #expect(viewModel.canvasContentSize == PolicyCanvasLayout.minimumCanvasSize)
    #expect((viewModel.canvasContentSize.width * viewModel.zoom).isFinite)
    #expect((viewModel.canvasContentSize.height * viewModel.zoom).isFinite)
  }

  @Test("view model init sanitizes non-finite zoom")
  func viewModelInitSanitizesNonFiniteZoom() {
    let viewModel = PolicyCanvasViewModel(
      nodes: [],
      groups: [],
      edges: [],
      zoom: .infinity
    )

    #expect(viewModel.zoom == PolicyCanvasLayout.defaultZoom)
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

  @Test("ending an outside-node drag does not synchronously export unrelated groups")
  func endingOutsideNodeDragDoesNotSynchronouslyExportUnrelatedGroups() {
    var member = PolicyCanvasNode(
      id: "member",
      title: "Member",
      kind: .condition,
      position: CGPoint(x: 100, y: 100)
    )
    member.groupID = "group-a"
    let outside = PolicyCanvasNode(
      id: "outside",
      title: "Outside",
      kind: .decision,
      position: CGPoint(x: 700, y: 100)
    )
    let group = PolicyCanvasGroup(
      id: "group-a",
      title: "Group A",
      frame: CGRect(x: 80, y: 80, width: 220, height: 180),
      tone: .evaluation
    )
    let viewModel = PolicyCanvasViewModel(
      nodes: [member, outside],
      groups: [group],
      edges: [],
      zoom: 1
    )
    viewModel.markSavedDocument(viewModel.exportDocument())
    let staleFrame = CGRect(x: -400, y: -400, width: 80, height: 80)
    if let groupIndex = viewModel.groups.firstIndex(where: { $0.id == "group-a" }) {
      viewModel.groups[groupIndex].frame = staleFrame
    }
    viewModel.documentDirty = false

    viewModel.dragNode("outside", translation: CGSize(width: 40, height: 0))
    viewModel.endNodeDrag("outside", translation: CGSize(width: 40, height: 0))

    #expect(viewModel.group("group-a")?.frame == staleFrame)
    #expect(viewModel.documentDirty)
  }

  @Test("node drag end queues automation compilation after the visual commit")
  func nodeDragEndQueuesAutomationCompilationAfterVisualCommit() async throws {
    let firstSource = PolicyCanvasNode(
      id: "source-a",
      title: "Clipboard Source",
      kind: .source,
      position: CGPoint(x: 80, y: 80)
    )
    let secondSource = PolicyCanvasNode(
      id: "source-b",
      title: "Manual Paste Source",
      kind: .source,
      position: CGPoint(x: 80, y: 240)
    )
    let viewModel = PolicyCanvasViewModel(
      nodes: [firstSource, secondSource],
      groups: [],
      edges: [],
      zoom: 1
    )
    #expect(viewModel.automationPolicyCompilation.policy(compiledFrom: "source-b")?.priority == 2)

    viewModel.dragNode("source-b", translation: CGSize(width: 0, height: -220))
    viewModel.endNodeDrag("source-b", translation: CGSize(width: 0, height: -220))

    #expect(viewModel.node("source-b")?.position == CGPoint(x: 80, y: 20))
    #expect(viewModel.automationPolicyCompilation.policy(compiledFrom: "source-b")?.priority == 2)

    for _ in 0..<50
    where viewModel.automationPolicyCompilation.policy(compiledFrom: "source-b")?
      .priority != 1
    {
      try await Task.sleep(for: .milliseconds(10))
    }

    #expect(viewModel.automationPolicyCompilation.policy(compiledFrom: "source-b")?.priority == 1)
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

    #expect(riskKind?.discriminator == "risk_classifier")
    #expect(riskKind?.field == .riskScore)
    #expect(riskKind?.threshold == 74)
    if case let .riskClassifier(_, _, highRiskReasonCode, missingReasonCode) = riskKind {
      #expect(highRiskReasonCode == .riskAboveThreshold)
      #expect(missingReasonCode == .humanRequired)
    } else {
      Issue.record("riskKind is not riskClassifier")
    }
    #expect(evidenceKind?.discriminator == "evidence_check")
    #expect(evidenceKind?.checks.first?.field == .checksGreen)
    #expect(evidenceKind?.checks.first?.failReasonCode == .checksNotGreen)
    #expect(failureCondition?.condition == "evidence_failure")
    #expect(failureCondition?.reasonCode == "checks_not_green")
  }

  @Test("if then else export derives branch conditions from then and else ports")
  func ifThenElseExportDerivesBranchConditions() {
    let document = TaskBoardPolicyPipelineDocument(
      revision: 14,
      mode: .draft,
      nodes: [
        TaskBoardPolicyPipelineNode(
          id: "node-entry",
          label: "Entry",
          kind: .workflowEntry(PolicyWorkflowEntry(workflowId: "reviews_auto")),
          inputPorts: [],
          outputPorts: ["out"]
        ),
        TaskBoardPolicyPipelineNode(
          id: "node-if",
          label: "Checks green?",
          kind: .ifThenElse(PolicyIfThenElseCondition(field: .checksGreen, predicate: .isTrue)),
          inputPorts: ["in"],
          outputPorts: ["then", "else"]
        ),
        TaskBoardPolicyPipelineNode(
          id: "node-allow",
          label: "Allow",
          kind: .finish(PolicyFinishNode(decision: .allow, reasonCode: .defaultAllow)),
          inputPorts: ["in"]
        ),
        TaskBoardPolicyPipelineNode(
          id: "node-deny",
          label: "Deny",
          kind: .finish(PolicyFinishNode(decision: .deny, reasonCode: .checksNotGreen)),
          inputPorts: ["in"]
        ),
      ],
      edges: [
        TaskBoardPolicyPipelineEdge(
          id: "edge-entry-if",
          fromNodeId: "node-entry",
          fromPort: "out",
          toNodeId: "node-if",
          toPort: "in"
        ),
        TaskBoardPolicyPipelineEdge(
          id: "edge-if-then",
          fromNodeId: "node-if",
          fromPort: "then",
          toNodeId: "node-allow",
          toPort: "in"
        ),
        TaskBoardPolicyPipelineEdge(
          id: "edge-if-else",
          fromNodeId: "node-if",
          fromPort: "else",
          toNodeId: "node-deny",
          toPort: "in"
        ),
      ],
      groups: [],
      layout: TaskBoardPolicyPipelineLayout(
        nodes: [
          TaskBoardPolicyPipelineNodeLayout(nodeId: "node-entry", x: 20, y: 40),
          TaskBoardPolicyPipelineNodeLayout(nodeId: "node-if", x: 280, y: 40),
          TaskBoardPolicyPipelineNodeLayout(nodeId: "node-allow", x: 540, y: 0),
          TaskBoardPolicyPipelineNodeLayout(nodeId: "node-deny", x: 540, y: 120),
        ]
      ),
      policyTraceIds: []
    )
    let viewModel = PolicyCanvasViewModel.sample()

    viewModel.load(document: document, simulation: nil, audit: nil)
    let exported = viewModel.exportDocument()
    let thenCondition = exported.edges.first { $0.id == "edge-if-then" }?.condition
    let elseCondition = exported.edges.first { $0.id == "edge-if-else" }?.condition

    #expect(thenCondition?.condition == "condition_true")
    #expect(elseCondition?.condition == "condition_false")

    let encoded = try! JSONEncoder().encode(exported)
    let json = String(decoding: encoded, as: UTF8.self)
    #expect(json.contains(#""kind":"if_then_else""#))
    #expect(json.contains(#""field":"checks_green""#))
    #expect(json.contains(#""predicate":{"predicate":"is_true"}"#))
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

    #expect(policyCanvasEdge(edge)?.label.isEmpty == true)
  }

  @Test("edges map through the load chokepoint when nodes declare no ports")
  func edgesMapWhenNodesDeclareNoPorts() {
    // Regression: the ELK guard dropped edges whose endpoints did not match a
    // declared node port. Terminal port markers are seeded from the edges
    // themselves, so an edge between two existing nodes must always map even
    // when the wire carried no ports (e.g. a casing-stripped decode).
    let document = TaskBoardPolicyPipelineDocument(
      revision: 1,
      mode: .draft,
      nodes: [
        TaskBoardPolicyPipelineNode(
          id: "source",
          label: "Source",
          kind: .workflowEntry(PolicyWorkflowEntry(workflowId: "reviews_auto")),
          inputPorts: [],
          outputPorts: []
        ),
        TaskBoardPolicyPipelineNode(
          id: "target",
          label: "Target",
          kind: .finish(PolicyFinishNode(decision: .allow, reasonCode: .defaultAllow)),
          inputPorts: [],
          outputPorts: []
        ),
      ],
      edges: [
        TaskBoardPolicyPipelineEdge(
          id: "edge-source-target",
          fromNodeId: "source",
          fromPort: "out",
          toNodeId: "target",
          toPort: "in"
        ),
      ],
      groups: [],
      layout: TaskBoardPolicyPipelineLayout(nodes: []),
      policyTraceIds: []
    )

    let graph = policyCanvasLoadedGraph(from: document, policyGroupTitle: nil)

    #expect(graph.mappedEdges.count == 1)
    #expect(graph.mappedEdges.first?.id == "edge-source-target")
  }

  @Test("if then else branch labels prefer the source port over condition tokens")
  func ifThenElseBranchLabelsPreferPorts() {
    let thenEdge = TaskBoardPolicyPipelineEdge(
      id: "edge-if-then",
      fromNodeId: "node-if",
      fromPort: "then",
      toNodeId: "node-allow",
      toPort: "in",
      condition: TaskBoardPolicyPipelineEdgeCondition(condition: "condition_true")
    )
    let elseEdge = TaskBoardPolicyPipelineEdge(
      id: "edge-if-else",
      fromNodeId: "node-if",
      fromPort: "else",
      toNodeId: "node-deny",
      toPort: "in",
      condition: TaskBoardPolicyPipelineEdgeCondition(condition: "condition_false")
    )

    #expect(policyCanvasEdge(thenEdge)?.label == "then")
    #expect(policyCanvasEdge(elseEdge)?.label == "else")
  }

  @Test("tool rail spacing scales with font scale")
  func toolRailSpacingScalesWithFontScale() {
    let regular = PolicyCanvasToolRailMetrics(fontScale: 1)
    let larger = PolicyCanvasToolRailMetrics(fontScale: 1.5)

    #expect(larger.railWidth > regular.railWidth)
    #expect(larger.buttonWidth > regular.buttonWidth)
    #expect(larger.buttonHeight > regular.buttonHeight)
    #expect(larger.rowIconSize > regular.rowIconSize)
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
