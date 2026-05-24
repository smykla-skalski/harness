import HarnessMonitorKit
import SwiftUI

/// Per-row binding helpers and the bottom "Policy" metrics block for
/// `PolicyCanvasInspector`. Kept in a separate file so the main inspector
/// view stays under the 420-line cap. The bindings are file-private to the
/// inspector seam through their explicit `selected*` names; they each only
/// have one caller (the matching row in `PolicyCanvasInspectorViews.swift`).
extension PolicyCanvasInspector {
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

  var canvasMetrics: some View {
    PolicyCanvasInspectorSection(title: "Policy") {
      PolicyCanvasInspectorRow(label: "Summary", value: viewModel.policySummary)
      PolicyCanvasInspectorRow(
        label: "Zoom",
        value: "\(Int((viewModel.zoom * 100).rounded()))%"
      )
      PolicyCanvasInspectorRow(
        label: "Promote",
        value: viewModel.promoteDisabledReason ?? "Ready"
      )
      PolicyCanvasInspectorRow(
        label: "Validation",
        value: validationSummary
      )
    }
  }

  /// Validation summary surfaced in the inspector footer. Reports the full
  /// daemon + local issue count so the user sees how many issues exist
  /// without expanding the chrome panel. Stays "OK" when both producers are
  /// clean, distinct from "No data" before a simulation has been run.
  var validationSummary: String {
    let issues = viewModel.allValidationIssues
    if issues.isEmpty {
      return viewModel.latestSimulation == nil ? "No data" : "OK"
    }
    let errors = issues.filter { $0.severity == .error }.count
    let warnings = issues.filter { $0.severity == .warning }.count
    var parts: [String] = []
    if errors > 0 {
      parts.append("\(errors) error\(errors == 1 ? "" : "s")")
    }
    if warnings > 0 {
      parts.append("\(warnings) warning\(warnings == 1 ? "" : "s")")
    }
    return parts.joined(separator: ", ")
  }
}
