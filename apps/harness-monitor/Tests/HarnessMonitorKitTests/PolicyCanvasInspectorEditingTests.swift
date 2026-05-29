import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

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
}
