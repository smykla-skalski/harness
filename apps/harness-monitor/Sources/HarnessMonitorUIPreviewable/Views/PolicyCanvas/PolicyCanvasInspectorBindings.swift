import HarnessMonitorKit
import SwiftUI

/// Per-row binding helpers and the bottom "Policy" metrics block for
/// `PolicyCanvasInspector`. Kept in a separate file so the main inspector
/// view stays under the 420-line cap. The bindings are file-private to the
/// inspector seam through their explicit `selected*` names; they each only
/// have one caller (the matching row in `PolicyCanvasInspectorViews.swift`).
extension PolicyCanvasEditForm {
  static let noneGroupTag = "__none__"

  func selectedNodeKindBinding(_ node: PolicyCanvasNode) -> Binding<PolicyCanvasNodeKind> {
    Binding(
      get: { node.kind },
      set: { viewModel.commitSelectedNodeKind($0) }
    )
  }

  func selectedNodeGroupBinding(_ node: PolicyCanvasNode) -> Binding<String> {
    Binding(
      get: { node.groupID ?? Self.noneGroupTag },
      set: { viewModel.commitSelectedNodeGroup($0 == Self.noneGroupTag ? nil : $0) }
    )
  }

  var selectedGroupTitleBinding: Binding<String> {
    Binding(
      get: { viewModel.selectedGroup?.title ?? "" },
      set: { viewModel.commitSelectedGroupTitle($0) }
    )
  }

  var selectedEdgeLabelBinding: Binding<String> {
    Binding(
      get: { viewModel.selectedEdge?.label ?? "" },
      set: { viewModel.commitSelectedEdgeLabel($0) }
    )
  }

  func selectedPolicyActionBinding(
    _ policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> Binding<TaskBoardPolicyAction> {
    Binding(
      get: { policyKind.actions.first ?? policyKind.action ?? .spawnAgent },
      set: { viewModel.commitSelectedPolicyAction($0) }
    )
  }

  func selectedEvidenceFieldBinding(
    _ policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> Binding<TaskBoardPolicyEvidenceField> {
    Binding(
      get: { policyKind.checks.first?.field ?? policyKind.field ?? .checksGreen },
      set: { viewModel.commitSelectedEvidenceField($0) }
    )
  }

  func selectedRiskThresholdBinding(
    _ policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> Binding<Int> {
    Binding(
      get: { Int(policyKind.threshold ?? 0) },
      set: { viewModel.commitSelectedRiskThreshold($0) }
    )
  }

  func selectedReasonCodeBinding(
    _ policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> Binding<String> {
    Binding(
      get: { policyKind.reasonCode ?? policyKind.reasonCodes.first ?? "" },
      set: { viewModel.commitSelectedReasonCode($0) }
    )
  }

  func selectedRuleIDBinding(
    _ policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> Binding<String> {
    Binding(
      get: { policyKind.ruleId ?? "" },
      set: { viewModel.commitSelectedRuleID($0) }
    )
  }

  func selectedDecisionBinding(
    _ policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> Binding<String> {
    Binding(
      get: { policyKind.decision ?? "allow" },
      set: { viewModel.commitSelectedDecision($0) }
    )
  }

  var inspectorTitle: String {
    if !viewModel.secondarySelections.isEmpty {
      return "Multiple items selected"
    }
    if let node = viewModel.selectedNode {
      return node.title
    }
    if let group = viewModel.selectedGroup {
      return group.title
    }
    if let edge = viewModel.selectedEdge {
      return edge.label.isEmpty ? "Connection details" : edge.label
    }
    return "Canvas summary"
  }

  var inspectorSubtitle: String {
    if !viewModel.secondarySelections.isEmpty {
      return "Review the current selection before you make a bulk change."
    }
    if let node = viewModel.selectedNode {
      return "Policy step · \(node.kind.title)"
    }
    if let group = viewModel.selectedGroup {
      return "Group · \(group.tone.policyCanvasTitle)"
    }
    if let edge = viewModel.selectedEdge {
      let sourceTitle = edgeEndpointTitle(edge.source.nodeID)
      let targetTitle = edgeEndpointTitle(edge.target.nodeID)
      return "Connection · \(sourceTitle) to \(targetTitle)"
    }
    return "Select a step, path, or group to edit its policy."
  }

  func edgeEndpointTitle(_ nodeID: String) -> String {
    viewModel.node(nodeID)?.title ?? nodeID
  }
}
