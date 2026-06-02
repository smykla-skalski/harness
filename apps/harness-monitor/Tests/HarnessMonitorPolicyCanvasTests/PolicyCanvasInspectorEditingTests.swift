import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas

/// Wave 4K P08: inspector commit-on-Enter property edits route through the
/// undo funnel. Each commit lands one undo step on the manager; per-
/// keystroke writes stay local to the inspector text fields and never
/// reach this layer.
@Suite("Policy canvas inspector editing")
@MainActor
struct PolicyCanvasInspectorEditingTests {
  @Test("node subtitle commit lands through undo funnel")
  func nodeSubtitleCommitFunnelsThroughUndo() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    viewModel.select(.node("risk-score"))
    let originalSubtitle = viewModel.node("risk-score")?.subtitle ?? ""

    viewModel.commitSelectedNodeSubtitle("Threshold gate")

    #expect(viewModel.node("risk-score")?.subtitle == "Threshold gate")
    #expect(undoManager.canUndo)
    #expect(undoManager.undoActionName == "Edit Subtitle")
    #expect(viewModel.documentDirty)

    undoManager.undo()

    #expect(viewModel.node("risk-score")?.subtitle == originalSubtitle)
  }

  @Test("node subtitle commit no-ops when value unchanged")
  func nodeSubtitleCommitNoOpOnEqualValue() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    viewModel.select(.node("risk-score"))
    let originalSubtitle = viewModel.node("risk-score")?.subtitle ?? ""

    viewModel.commitSelectedNodeSubtitle(originalSubtitle)

    #expect(!undoManager.canUndo, "commit with unchanged value must not register undo")
  }

  @Test("node policy kind picker commit funnels and inverses cleanly")
  func nodePolicyKindCommitFunnelsThroughUndo() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    viewModel.select(.node("risk-score"))
    let originalKind = viewModel.node("risk-score")?.policyKind

    let newKind = TaskBoardPolicyPipelineNodeKind(
      kind: "evidence_check",
      checks: [
        TaskBoardPolicyEvidenceCheck(
          field: .checksGreen,
          pass: TaskBoardPolicyEvidencePredicate(predicate: .isTrue),
          failReasonCode: "checks_not_green",
          missingReasonCode: "checks_missing"
        )
      ]
    )

    viewModel.commitSelectedNodePolicyKind(newKind)

    #expect(viewModel.node("risk-score")?.policyKind == newKind)
    #expect(undoManager.canUndo)
    #expect(undoManager.undoActionName == "Edit Node Binding")

    undoManager.undo()

    #expect(viewModel.node("risk-score")?.policyKind == originalKind)
  }

  @Test("edge label commit lands through undo funnel")
  func edgeLabelCommitFunnelsThroughUndo() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    viewModel.select(.edge("edge-intake-risk"))
    let original = viewModel.edges.first { $0.id == "edge-intake-risk" }?.label ?? ""

    viewModel.commitSelectedEdgeLabel("dispatched")

    let edge = viewModel.edges.first { $0.id == "edge-intake-risk" }
    #expect(edge?.label == "dispatched")
    #expect(undoManager.canUndo)
    #expect(undoManager.undoActionName == "Edit Label")

    undoManager.undo()

    #expect(viewModel.edges.first { $0.id == "edge-intake-risk" }?.label == original)
  }

  @Test("edge condition commit lands through undo funnel")
  func edgeConditionCommitFunnelsThroughUndo() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    viewModel.select(.edge("edge-intake-risk"))
    let originalCondition = viewModel.edges.first { $0.id == "edge-intake-risk" }?.condition ?? ""

    viewModel.commitSelectedEdgeCondition("risk_score_above_50")

    let edge = viewModel.edges.first { $0.id == "edge-intake-risk" }
    #expect(edge?.condition == "risk_score_above_50")
    #expect(undoManager.canUndo)
    #expect(undoManager.undoActionName == "Edit Condition")

    undoManager.undo()

    #expect(
      viewModel.edges.first { $0.id == "edge-intake-risk" }?.condition == originalCondition
    )
  }

  @Test("group title commit lands through undo funnel")
  func groupTitleCommitFunnelsThroughUndo() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    viewModel.select(.group("group-evaluation"))
    let original = viewModel.group("group-evaluation")?.title ?? ""

    viewModel.commitSelectedGroupTitle("Decision wall")

    #expect(viewModel.group("group-evaluation")?.title == "Decision wall")
    #expect(undoManager.canUndo)
    #expect(undoManager.undoActionName == "Rename Group")

    undoManager.undo()

    #expect(viewModel.group("group-evaluation")?.title == original)
  }

  @Test("group tone commit lands through undo funnel")
  func groupToneCommitFunnelsThroughUndo() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    viewModel.select(.group("group-evaluation"))
    let originalTone = viewModel.group("group-evaluation")?.tone

    viewModel.commitSelectedGroupTone(.release)

    #expect(viewModel.group("group-evaluation")?.tone == .release)
    #expect(undoManager.canUndo)
    #expect(undoManager.undoActionName == "Edit Tone")

    undoManager.undo()

    #expect(viewModel.group("group-evaluation")?.tone == originalTone)
  }

  @Test("inspector commits do nothing when selection is not the expected kind")
  func inspectorCommitsGuardSelectionKind() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    viewModel.select(.edge("edge-intake-risk"))

    // Node-only commit while an edge is selected must be a no-op.
    viewModel.commitSelectedNodeSubtitle("hello")
    #expect(!undoManager.canUndo)

    // Group-only commit while an edge is selected must also be a no-op.
    viewModel.commitSelectedGroupTitle("hello")
    #expect(!undoManager.canUndo)
    viewModel.commitSelectedGroupTone(.intake)
    #expect(!undoManager.canUndo)
  }

  @Test("edge condition round-trips through exportDocument")
  func edgeConditionRoundTripsThroughExport() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.edge("edge-intake-risk"))

    viewModel.commitSelectedEdgeCondition("custom_branch_predicate")

    let document = viewModel.exportDocument()
    let edge = document.edges.first { $0.id == "edge-intake-risk" }
    #expect(edge?.condition.condition == "custom_branch_predicate")
  }

  @Test("node title commit lands through undo funnel")
  func nodeTitleCommitFunnelsThroughUndo() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    viewModel.select(.node("risk-score"))
    let originalTitle = viewModel.node("risk-score")?.title ?? ""

    viewModel.commitSelectedNodeTitle("Risk gate")

    #expect(viewModel.node("risk-score")?.title == "Risk gate")
    #expect(undoManager.canUndo)
    #expect(undoManager.undoActionName == "Rename Node")
    #expect(viewModel.documentDirty)

    undoManager.undo()

    #expect(viewModel.node("risk-score")?.title == originalTitle)
  }

  @Test("node title commit no-ops when value unchanged")
  func nodeTitleCommitNoOpOnEqualValue() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    viewModel.select(.node("risk-score"))
    let originalTitle = viewModel.node("risk-score")?.title ?? ""

    viewModel.commitSelectedNodeTitle(originalTitle)

    #expect(!undoManager.canUndo)
  }

  @Test("node title reverting to the saved value clears dirty state")
  func nodeTitleRevertToSavedValueClearsDirtyState() async {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.markSavedDocument(viewModel.exportDocument())
    viewModel.select(.node("risk-score"))
    let originalTitle = viewModel.node("risk-score")?.title ?? ""

    viewModel.commitSelectedNodeTitle("Risk gate")
    #expect(viewModel.documentDirty)

    viewModel.commitSelectedNodeTitle(originalTitle)
    await waitForPolicyCanvasDirtyReconciliation(viewModel)

    #expect(viewModel.node("risk-score")?.title == originalTitle)
    #expect(!viewModel.documentDirty)
    #expect(viewModel.draftStatusText == "Saved draft")
  }

  @Test("node group commit lands through undo funnel")
  func nodeGroupCommitFunnelsThroughUndo() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    viewModel.select(.node("risk-score"))
    let originalGroupID = viewModel.node("risk-score")?.groupID

    viewModel.commitSelectedNodeGroup("group-intake")

    #expect(viewModel.node("risk-score")?.groupID == "group-intake")
    #expect(undoManager.canUndo)
    #expect(undoManager.undoActionName == "Change Node Group")

    undoManager.undo()

    #expect(viewModel.node("risk-score")?.groupID == originalGroupID)
  }

  @Test("node group commit accepts nil to clear group membership")
  func nodeGroupCommitAcceptsNil() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    viewModel.select(.node("risk-score"))

    viewModel.commitSelectedNodeGroup(nil)

    #expect(viewModel.node("risk-score")?.groupID == nil)
    #expect(undoManager.canUndo)

    undoManager.undo()

    #expect(viewModel.node("risk-score")?.groupID != nil)
  }

  @Test("node kind commit captures removed edges and restores them on undo")
  func nodeKindCommitCapturesRemovedEdgesAndRestoresOnUndo() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    let nodeID = "risk-score"
    viewModel.select(.node(nodeID))
    let originalKind = viewModel.node(nodeID)?.kind ?? .condition
    // Capture incident edges that the kind switch will prune. A kind
    // change replaces both input and output ports so any incident edge
    // whose endpoint references a port the new kind does not carry is
    // dropped.
    let incidentEdgeIDs = viewModel.edges.filter { edge in
      edge.source.nodeID == nodeID || edge.target.nodeID == nodeID
    }.map(\.id)
    #expect(!incidentEdgeIDs.isEmpty, "Sample must include risk-score edges")

    // Pick a kind that does not match the current kind. Sample's risk-score
    // is a condition; .source has no input port so its incident input
    // edges will prune.
    let newKind: PolicyCanvasNodeKind = originalKind == .source ? .condition : .source
    viewModel.commitSelectedNodeKind(newKind)

    #expect(viewModel.node(nodeID)?.kind == newKind)
    #expect(undoManager.canUndo)
    #expect(undoManager.undoActionName == "Change Node Kind")

    undoManager.undo()

    #expect(viewModel.node(nodeID)?.kind == originalKind)
    for edgeID in incidentEdgeIDs {
      #expect(
        viewModel.edges.contains { $0.id == edgeID },
        "edge \(edgeID) must be restored on undo"
      )
    }
  }

  @Test("node kind commit no-ops when picker selects the same kind")
  func nodeKindCommitNoOpOnEqualKind() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    viewModel.select(.node("risk-score"))
    let currentKind = viewModel.node("risk-score")?.kind ?? .condition

    viewModel.commitSelectedNodeKind(currentKind)

    #expect(!undoManager.canUndo)
  }

  @Test("visual kind picker preserves a compatible custom policy binding")
  func visualKindPickerPreservesCompatiblePolicyBinding() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    let nodeID = "risk-score"
    viewModel.select(.node(nodeID))

    // The sample risk-score node is a visual `.evidenceCheck`. Give it a
    // customized risk_classifier binding (threshold 75), so the policy kind
    // string already matches the risk_classifier visual kind the user is
    // about to pick.
    let customRisk = TaskBoardPolicyPipelineNodeKind(
      kind: "risk_classifier",
      field: .riskScore,
      threshold: 75,
      highRiskReasonCode: "risk_above_threshold",
      missingReasonCode: "human_required"
    )
    viewModel.commitSelectedNodePolicyKind(customRisk)
    #expect(viewModel.node(nodeID)?.policyKind == customRisk)

    // Switch the visual kind to risk classifier - its default policy kind
    // shares the kind string, so the custom binding must survive instead of
    // being reset to the default threshold of 50.
    viewModel.commitSelectedNodeKind(.riskClassifier)

    #expect(viewModel.node(nodeID)?.kind == .riskClassifier)
    #expect(viewModel.node(nodeID)?.policyKind == customRisk)
    #expect(viewModel.node(nodeID)?.policyKind?.threshold == 75)
  }

  @Test("visual kind picker resets the policy binding for an incompatible kind")
  func visualKindPickerResetsIncompatiblePolicyBinding() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.node("risk-score"))

    let customRisk = TaskBoardPolicyPipelineNodeKind(
      kind: "risk_classifier",
      field: .riskScore,
      threshold: 75
    )
    viewModel.commitSelectedNodePolicyKind(customRisk)

    // Trigger has an incompatible policy kind string, so the binding resets
    // to the trigger default.
    viewModel.commitSelectedNodeKind(.trigger)

    #expect(viewModel.node("risk-score")?.kind == .trigger)
    let expectedKind = PolicyCanvasNodeKind.trigger.defaultPolicyKind
    #expect(viewModel.node("risk-score")?.policyKind == expectedKind)
  }

  @Test("if then else evidence-field commits keep the canonical binding")
  func ifThenElseEvidenceFieldCommitKeepsCanonicalBinding() throws {
    let viewModel = makeEmptyCanvas()
    viewModel.createNode(kind: .ifThenElse, at: CGPoint(x: 240, y: 120))
    let nodeID = try #require(viewModel.nodes.last?.id)
    viewModel.select(.node(nodeID))
    viewModel.commitSelectedNodePolicyKind(
      TaskBoardPolicyPipelineNodeKind(
        kind: "if_then_else",
        checks: [legacyEvidenceCheck(field: .checksGreen)]
      )
    )

    viewModel.commitSelectedEvidenceField(.protectedPathTouched)

    let kind = try #require(viewModel.node(nodeID)?.policyKind)
    #expect(kind.kind == "if_then_else")
    #expect(kind.field == .protectedPathTouched)
    #expect(kind.predicate?.predicate == .isTrue)
    #expect(kind.checks.isEmpty)
  }

  @Test("if then else predicate commits reuse legacy evidence fields")
  func ifThenElsePredicateCommitReusesLegacyEvidenceField() throws {
    let viewModel = makeEmptyCanvas()
    viewModel.createNode(kind: .ifThenElse, at: CGPoint(x: 240, y: 120))
    let nodeID = try #require(viewModel.nodes.last?.id)
    viewModel.select(.node(nodeID))
    viewModel.commitSelectedNodePolicyKind(
      TaskBoardPolicyPipelineNodeKind(
        kind: "if_then_else",
        checks: [legacyEvidenceCheck(field: .unresolvedRequestedChanges)]
      )
    )

    viewModel.commitSelectedConditionPredicate(.isZero)

    let kind = try #require(viewModel.node(nodeID)?.policyKind)
    #expect(kind.kind == "if_then_else")
    #expect(kind.field == .unresolvedRequestedChanges)
    #expect(kind.predicate?.predicate == .isZero)
    #expect(kind.checks.isEmpty)
  }

  @Test("switch case commits update the selected switch binding")
  func switchCaseCommitsUpdateBinding() throws {
    let viewModel = makeEmptyCanvas()
    viewModel.createNode(kind: .switch, at: CGPoint(x: 240, y: 120))
    let nodeID = try #require(viewModel.nodes.last?.id)
    viewModel.select(.node(nodeID))

    viewModel.commitSelectedSwitchArmField(.protectedPathTouched, at: 0)
    viewModel.commitSelectedSwitchArmPredicate(.isPresent, at: 0)

    let kind = try #require(viewModel.node(nodeID)?.policyKind)
    let arm = try #require(kind.arms.first)
    #expect(kind.kind == "switch")
    #expect(kind.arms.count == 1)
    #expect(arm.port == "case_1")
    #expect(arm.field == .protectedPathTouched)
    #expect(arm.predicate.predicate == .isPresent)
    #expect(viewModel.node(nodeID)?.outputPorts.map(\.title) == ["case_1", "default"])
  }

  @Test("switch case removal retargets later edges and undo restores them")
  func switchCaseRemovalRetargetsLaterEdgesAndUndoRestoresThem() throws {
    let viewModel = makeEmptyCanvas()
    viewModel.createNode(kind: .switch, at: CGPoint(x: 240, y: 120))
    let switchID = try #require(viewModel.nodes.last?.id)
    viewModel.select(.node(switchID))
    viewModel.addSelectedSwitchArm()

    viewModel.createNode(kind: .finish, at: CGPoint(x: 520, y: 40))
    let firstFinishID = try #require(viewModel.nodes.last?.id)
    viewModel.createNode(kind: .finish, at: CGPoint(x: 520, y: 220))
    let secondFinishID = try #require(viewModel.nodes.last?.id)

    #expect(
      viewModel.connectDroppedPortPayloads(
        ["policy-canvas-port|\(switchID)|output-case_1"],
        targetNodeID: firstFinishID,
        targetPortID: "input-in"
      )
    )
    #expect(
      viewModel.connectDroppedPortPayloads(
        ["policy-canvas-port|\(switchID)|output-case_2"],
        targetNodeID: secondFinishID,
        targetPortID: "input-in"
      )
    )

    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    viewModel.select(.node(switchID))

    viewModel.removeSelectedSwitchArm(at: 0)

    let switchNode = try #require(viewModel.node(switchID))
    #expect(switchNode.outputPorts.map(\.title) == ["case_1", "default"])
    let outgoing = viewModel.edges.filter { $0.source.nodeID == switchID }
    #expect(outgoing.count == 1)
    let remaining = try #require(outgoing.first)
    #expect(remaining.source.portID == "output-case_1")
    #expect(remaining.target.nodeID == secondFinishID)
    #expect(undoManager.canUndo)
    #expect(undoManager.undoActionName == "Edit Switch Cases")

    undoManager.undo()

    let restoredNode = try #require(viewModel.node(switchID))
    #expect(restoredNode.outputPorts.map(\.title) == ["case_1", "case_2", "default"])
    let restoredEdges = viewModel.edges.filter { $0.source.nodeID == switchID }
    #expect(restoredEdges.count == 2)
    #expect(
      restoredEdges.contains {
        $0.source.portID == "output-case_1" && $0.target.nodeID == firstFinishID
      }
    )
    #expect(
      restoredEdges.contains {
        $0.source.portID == "output-case_2" && $0.target.nodeID == secondFinishID
      }
    )
  }

  @Test("switch export normalizes ports and import restores canvas ids")
  func switchExportNormalizesPortsAndImportRestoresCanvasIDs() throws {
    let viewModel = makeEmptyCanvas()
    viewModel.createNode(kind: .actionStep, at: CGPoint(x: 40, y: 120))
    let sourceID = try #require(viewModel.nodes.last?.id)
    viewModel.createNode(kind: .switch, at: CGPoint(x: 280, y: 120))
    let switchID = try #require(viewModel.nodes.last?.id)
    viewModel.createNode(kind: .finish, at: CGPoint(x: 520, y: 120))
    let finishID = try #require(viewModel.nodes.last?.id)

    #expect(
      viewModel.connectDroppedPortPayloads(
        ["policy-canvas-port|\(sourceID)|output-out"],
        targetNodeID: switchID,
        targetPortID: "input-in"
      )
    )
    #expect(
      viewModel.connectDroppedPortPayloads(
        ["policy-canvas-port|\(switchID)|output-case_1"],
        targetNodeID: finishID,
        targetPortID: "input-in"
      )
    )

    let exported = viewModel.exportDocument()
    let exportedSwitch = try #require(exported.nodes.first(where: { $0.id == switchID }))
    #expect(exportedSwitch.inputs.map(\.id) == ["in"])
    #expect(exportedSwitch.outputs.map(\.id) == ["case_1", "default"])

    let exportedEntryEdge = try #require(exported.edges.first(where: { $0.toNodeId == switchID }))
    #expect(exportedEntryEdge.toPort == "in")

    let exportedBranchEdge = try #require(exported.edges.first(where: { $0.fromNodeId == switchID }))
    #expect(exportedBranchEdge.fromPort == "case_1")

    let reloaded = makeEmptyCanvas()
    reloaded.applyDocument(document: exported, simulation: nil, audit: nil)

    let reloadedSwitch = try #require(reloaded.node(switchID))
    #expect(reloadedSwitch.inputPorts.map(\.id) == ["input-in"])
    #expect(reloadedSwitch.outputPorts.map(\.id) == ["output-case_1", "output-default"])

    let reloadedEntryEdge = try #require(reloaded.edges.first(where: { $0.target.nodeID == switchID }))
    #expect(reloadedEntryEdge.target.portID == "input-in")

    let reloadedBranchEdge = try #require(reloaded.edges.first(where: { $0.source.nodeID == switchID }))
    #expect(reloadedBranchEdge.source.portID == "output-case_1")
  }

  @Test("switch import tolerates legacy prefixed persisted ports")
  func switchImportToleratesLegacyPrefixedPersistedPorts() throws {
    let viewModel = makeEmptyCanvas()
    viewModel.createNode(kind: .actionStep, at: CGPoint(x: 40, y: 120))
    let sourceID = try #require(viewModel.nodes.last?.id)
    viewModel.createNode(kind: .switch, at: CGPoint(x: 280, y: 120))
    let switchID = try #require(viewModel.nodes.last?.id)
    viewModel.createNode(kind: .finish, at: CGPoint(x: 520, y: 120))
    let finishID = try #require(viewModel.nodes.last?.id)

    #expect(
      viewModel.connectDroppedPortPayloads(
        ["policy-canvas-port|\(sourceID)|output-out"],
        targetNodeID: switchID,
        targetPortID: "input-in"
      )
    )
    #expect(
      viewModel.connectDroppedPortPayloads(
        ["policy-canvas-port|\(switchID)|output-case_1"],
        targetNodeID: finishID,
        targetPortID: "input-in"
      )
    )

    var legacyDocument = viewModel.exportDocument()
    let switchIndex = try #require(legacyDocument.nodes.firstIndex(where: { $0.id == switchID }))
    legacyDocument.nodes[switchIndex].inputPorts = ["input-in"]
    legacyDocument.nodes[switchIndex].outputPorts = ["output-case_1", "output-default"]
    for index in legacyDocument.edges.indices {
      if legacyDocument.edges[index].toNodeId == switchID {
        legacyDocument.edges[index].toPort = "input-in"
      }
      if legacyDocument.edges[index].fromNodeId == switchID {
        legacyDocument.edges[index].fromPort = "output-case_1"
      }
    }

    let reloaded = makeEmptyCanvas()
    reloaded.applyDocument(document: legacyDocument, simulation: nil, audit: nil)

    let reloadedSwitch = try #require(reloaded.node(switchID))
    #expect(reloadedSwitch.inputPorts.map(\.id) == ["input-in"])
    #expect(reloadedSwitch.outputPorts.map(\.id) == ["output-case_1", "output-default"])

    let reloadedEntryEdge = try #require(reloaded.edges.first(where: { $0.target.nodeID == switchID }))
    #expect(reloadedEntryEdge.target.portID == "input-in")

    let reloadedBranchEdge = try #require(reloaded.edges.first(where: { $0.source.nodeID == switchID }))
    #expect(reloadedBranchEdge.source.portID == "output-case_1")
  }

  @Test("group flash announces landed node on status callback")
  func groupFlashAnnouncesLandedNode() {
    let viewModel = PolicyCanvasViewModel.sample()
    var statuses: [String] = []
    viewModel.statusCallback = { @MainActor message in
      statuses.append(message)
    }

    let accepted = viewModel.dropPalettePayloadsOnGroup(
      [viewModel.palettePayload(for: .condition)],
      groupID: "group-intake",
      at: CGPoint(x: 200, y: 200)
    )

    #expect(accepted)
    // The status line must mention the destination group title ("Input
    // contract") so VoiceOver, which reads the inspector status as a
    // polite live region, hears the landed drop.
    #expect(statuses.contains { $0.contains("Added") && $0.contains("Input contract") })
  }

  private func makeEmptyCanvas() -> PolicyCanvasViewModel {
    PolicyCanvasViewModel(
      nodes: [],
      groups: [],
      edges: [],
      selection: nil,
      zoom: 1
    )
  }

  private func legacyEvidenceCheck(
    field: TaskBoardPolicyEvidenceField
  ) -> TaskBoardPolicyEvidenceCheck {
    TaskBoardPolicyEvidenceCheck(
      field: field,
      pass: TaskBoardPolicyEvidencePredicate(predicate: .isTrue),
      failReasonCode: "checks_not_green",
      missingReasonCode: "checks_missing"
    )
  }
}
