import HarnessMonitorKit
import SwiftUI

/// Inspector controls for the selected policy node, composed from the fields
/// declared in `PolicyCanvasInspectorFieldSchema`. The view is generic over the
/// field vocabulary: it iterates the schema's ordered fields and dispatches each
/// to its typed control, so adding a node kind is a schema data change rather
/// than a new per-kind form builder. Per-keystroke writes still flow through the
/// view-model's `commitSelected*` helpers (same pre-Wave-4K commit behavior).
struct PolicyCanvasInspectorNodePolicyControls: View {
  let viewModel: PolicyCanvasViewModel
  let node: PolicyCanvasNode
  @FocusState.Binding var focusedField: PolicyCanvasFocusedField?

  var body: some View {
    let policyKind = node.policyKind ?? taskBoardPolicyNodeKind(for: node.kind)
    let fields = PolicyCanvasInspectorFieldSchema.fields(for: policyKind)
    if fields.isEmpty {
      PolicyCanvasInspectorRow(label: "Binding", value: policyKind.kind)
    } else {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(fields) { field in
          PolicyCanvasInspectorField(label: field.rowLabel) {
            control(for: field, policyKind)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func control(
    for field: PolicyInspectorField,
    _ policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> some View {
    switch field {
    case .workflow:
      commitText(
        field, label: "Workflow", value: policyKind.workflow ?? "",
        focus: .workflow, placeholder: "default-task"
      ) { viewModel.commitSelectedWorkflow($0) }
    case .workflowID:
      commitText(
        field, label: "Workflow id", value: policyKind.workflowId ?? "",
        focus: .workflowID, placeholder: "reviews_auto"
      ) { viewModel.commitSelectedWorkflowID($0) }
    case .actionBinding:
      actionBindingControl(field, policyKind)
    case .actionID:
      commitText(
        field, label: "Action id", value: policyKind.actionId ?? "",
        focus: .actionID, placeholder: "reviews.approve"
      ) { viewModel.commitSelectedActionID($0) }
    case .evidenceField:
      evidenceControl(field, policyKind)
    case .riskThreshold:
      riskThresholdControl(field, policyKind)
    case .waitKind:
      waitKindControl(field, policyKind)
    case .waitDuration:
      commitText(
        field, label: "Duration in seconds",
        value: String(policyKind.wait?.durationSeconds ?? 900),
        focus: .waitDuration, placeholder: "900"
      ) { viewModel.commitSelectedWaitDuration(Int($0) ?? 900) }
    case .waitEventKey:
      commitText(
        field, label: "Wait event key", value: policyKind.wait?.eventKey ?? "",
        focus: .waitEventKey, placeholder: "reviews.checks_passed"
      ) { viewModel.commitSelectedWaitEventKey($0) }
    case .resumeKey:
      commitText(
        field, label: "Resume key", value: policyKind.resumeKey ?? "",
        focus: .resumeKey, placeholder: "checks-ready"
      ) { viewModel.commitSelectedResumeKey($0) }
    case .eventKey:
      commitText(
        field, label: "Event key", value: policyKind.eventKey ?? "",
        focus: .eventKey, placeholder: "reviews.checks_passed"
      ) { viewModel.commitSelectedEventKey($0) }
    case .handoffKey:
      commitText(
        field, label: "Handoff key", value: policyKind.handoffKey ?? "",
        focus: .handoffKey, placeholder: "next-handler"
      ) { viewModel.commitSelectedHandoffKey($0) }
    case .reasonCode:
      commitText(
        field, label: "Reason code",
        value: policyKind.reasonCode ?? policyKind.reasonCodes.first ?? "",
        focus: .reasonCode, placeholder: "Reason code"
      ) { viewModel.commitSelectedReasonCode($0) }
    case .ruleID:
      commitText(
        field, label: "Supervisor rule id", value: policyKind.ruleId ?? "",
        focus: .ruleID, placeholder: "Rule id"
      ) { viewModel.commitSelectedRuleID($0) }
    case .gateDecision, .finishDecision:
      decisionControl(field, policyKind)
    }
  }

  private func commitText(
    _ field: PolicyInspectorField,
    label: String,
    value: String,
    focus: PolicyCanvasFocusedField,
    placeholder: String,
    commit: @escaping (String) -> Void
  ) -> some View {
    PolicyCanvasInspectorCommitTextField(
      label: label,
      placeholder: placeholder,
      value: value,
      focusField: focus,
      focusedField: $focusedField,
      accessibilityIdentifier:
        HarnessMonitorAccessibility.policyCanvasInspectorField(field.accessibilityKey),
      commit: commit
    )
  }

  private func actionBindingControl(
    _ field: PolicyInspectorField,
    _ policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> some View {
    Picker("Action binding", selection: selectedPolicyActionBinding(policyKind)) {
      ForEach(TaskBoardPolicyAction.allCases) { action in
        Text(action.policyCanvasTitle).tag(action)
      }
    }
    .labelsHidden()
    .pickerStyle(.menu)
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.policyCanvasInspectorField(field.accessibilityKey)
    )
  }

  private func evidenceControl(
    _ field: PolicyInspectorField,
    _ policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> some View {
    Picker("Evidence field", selection: selectedEvidenceFieldBinding(policyKind)) {
      ForEach(TaskBoardPolicyEvidenceField.allCases, id: \.self) { evidence in
        Text(evidence.policyCanvasTitle).tag(evidence)
      }
    }
    .labelsHidden()
    .pickerStyle(.menu)
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.policyCanvasInspectorField(field.accessibilityKey)
    )
  }

  private func riskThresholdControl(
    _ field: PolicyInspectorField,
    _ policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> some View {
    Stepper(value: selectedRiskThresholdBinding(policyKind), in: 0...100) {
      Text("\(policyKind.threshold.map(Int.init) ?? 0)")
        .scaledFont(.caption.monospacedDigit().weight(.semibold))
        .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
    }
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.policyCanvasInspectorField(field.accessibilityKey)
    )
  }

  private func waitKindControl(
    _ field: PolicyInspectorField,
    _ policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> some View {
    Picker("Wait kind", selection: selectedWaitConditionKindBinding(policyKind)) {
      Text("Timer").tag(TaskBoardPolicyWaitCondition.Kind.timer)
      Text("Event").tag(TaskBoardPolicyWaitCondition.Kind.event)
    }
    .labelsHidden()
    .pickerStyle(.segmented)
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.policyCanvasInspectorField(field.accessibilityKey)
    )
  }

  private func decisionControl(
    _ field: PolicyInspectorField,
    _ policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> some View {
    Picker(
      field == .finishDecision ? "Finish behavior" : "Gate behavior",
      selection: selectedDecisionBinding(policyKind)
    ) {
      Text("Allow").tag("allow")
      Text("Deny").tag("deny")
    }
    .labelsHidden()
    .pickerStyle(.segmented)
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.policyCanvasInspectorField(field.accessibilityKey)
    )
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

  private func selectedWaitConditionKindBinding(
    _ policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> Binding<TaskBoardPolicyWaitCondition.Kind> {
    Binding(
      get: { policyKind.wait?.kind ?? .event },
      set: { viewModel.commitSelectedWaitConditionKind($0) }
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
