import HarnessMonitorKit
import SwiftUI

/// Per-policy-kind inspector controls (action/evidence/risk/reason/rule).
/// Pulled out of `PolicyCanvasInspectorViews.swift` so the host inspector
/// file stays under the 420-line cap; the controls themselves are unchanged
/// — per-keystroke writes still flow through the view-model's
/// `updateSelected*` helpers, which is the same pre-Wave-4K behavior
/// reserved for the discrete pickers below.
struct PolicyCanvasInspectorNodePolicyControls: View {
  let viewModel: PolicyCanvasViewModel
  let node: PolicyCanvasNode
  @FocusState.Binding var focusedField: PolicyCanvasFocusedField?

  var body: some View {
    let policyKind = node.policyKind ?? taskBoardPolicyNodeKind(for: node.kind)
    switch policyKind.kind {
    case "action_gate":
      policyActionField(policyKind)
    case "evidence_check":
      policyEvidenceField(policyKind)
    case "risk_classifier":
      riskThresholdField(policyKind)
    case "human_gate", "consensus_gate", "dry_run_gate":
      reasonCodeField(policyKind)
    case "supervisor_rule":
      supervisorRuleFields(policyKind)
    default:
      PolicyCanvasInspectorRow(label: "Binding", value: policyKind.kind)
    }
  }

  private func policyActionField(
    _ policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> some View {
    PolicyCanvasInspectorField(label: "Action") {
      Picker("Action binding", selection: selectedPolicyActionBinding(policyKind)) {
        ForEach(TaskBoardPolicyAction.allCases) { action in
          Text(action.policyCanvasTitle).tag(action)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.policyCanvasInspectorField("action-binding")
      )
    }
  }

  private func policyEvidenceField(
    _ policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> some View {
    PolicyCanvasInspectorField(label: "Evidence") {
      Picker("Evidence field", selection: selectedEvidenceFieldBinding(policyKind)) {
        ForEach(TaskBoardPolicyEvidenceField.allCases, id: \.self) { field in
          Text(field.policyCanvasTitle).tag(field)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.policyCanvasInspectorField("evidence-field")
      )
    }
  }

  private func riskThresholdField(
    _ policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> some View {
    PolicyCanvasInspectorField(label: "Risk") {
      Stepper(value: selectedRiskThresholdBinding(policyKind), in: 0...100) {
        Text("\(policyKind.threshold.map(Int.init) ?? 0)")
          .scaledFont(.caption.monospacedDigit().weight(.semibold))
          .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
      }
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.policyCanvasInspectorField("risk-threshold")
      )
    }
  }

  private func reasonCodeField(
    _ policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> some View {
    PolicyCanvasInspectorField(label: "Reason") {
      PolicyCanvasInspectorCommitTextField(
        label: "Reason code",
        placeholder: "Reason code",
        value: policyKind.reasonCode ?? policyKind.reasonCodes.first ?? "",
        focusField: .reasonCode,
        focusedField: $focusedField,
        accessibilityIdentifier:
          HarnessMonitorAccessibility.policyCanvasInspectorField("reason-code"),
        commit: { viewModel.commitSelectedReasonCode($0) }
      )
    }
  }

  private func supervisorRuleFields(
    _ policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      PolicyCanvasInspectorField(label: "Rule") {
        PolicyCanvasInspectorCommitTextField(
          label: "Supervisor rule id",
          placeholder: "Rule id",
          value: policyKind.ruleId ?? "",
          focusField: .ruleID,
          focusedField: $focusedField,
          accessibilityIdentifier:
            HarnessMonitorAccessibility.policyCanvasInspectorField("rule-id"),
          commit: { viewModel.commitSelectedRuleID($0) }
        )
      }
      PolicyCanvasInspectorField(label: "Decision") {
        Picker("Gate behavior", selection: selectedDecisionBinding(policyKind)) {
          Text("Allow").tag("allow")
          Text("Deny").tag("deny")
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.policyCanvasInspectorField("gate-behavior")
        )
      }
    }
  }

  private func selectedPolicyActionBinding(
    _ policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> Binding<TaskBoardPolicyAction> {
    Binding(
      get: { policyKind.actions.first ?? policyKind.action ?? .spawnAgent },
      set: { viewModel.commitSelectedPolicyAction($0) }
    )
  }

  private func selectedEvidenceFieldBinding(
    _ policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> Binding<TaskBoardPolicyEvidenceField> {
    Binding(
      get: { policyKind.checks.first?.field ?? policyKind.field ?? .checksGreen },
      set: { viewModel.commitSelectedEvidenceField($0) }
    )
  }

  private func selectedRiskThresholdBinding(
    _ policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> Binding<Int> {
    Binding(
      get: { Int(policyKind.threshold ?? 0) },
      set: { viewModel.commitSelectedRiskThreshold($0) }
    )
  }

  private func selectedDecisionBinding(
    _ policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> Binding<String> {
    Binding(
      get: { policyKind.decision ?? "allow" },
      set: { viewModel.commitSelectedDecision($0) }
    )
  }
}
