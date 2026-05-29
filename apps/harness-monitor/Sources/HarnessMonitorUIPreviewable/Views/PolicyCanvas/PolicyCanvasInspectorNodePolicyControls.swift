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
    case "trigger":
      workflowField(policyKind)
    case "workflow_entry":
      workflowIDField(policyKind)
    case "action_gate":
      policyActionField(policyKind)
    case "action_step":
      actionIDField(policyKind)
    case "evidence_check":
      policyEvidenceField(policyKind)
    case "risk_classifier":
      riskThresholdField(policyKind)
    case "wait_step":
      waitStepFields(policyKind)
    case "event_wait":
      eventWaitField(policyKind)
    case "handoff":
      handoffField(policyKind)
    case "human_gate", "consensus_gate", "dry_run_gate":
      reasonCodeField(policyKind)
    case "supervisor_rule":
      supervisorRuleFields(policyKind)
    case "finish":
      finishFields(policyKind)
    default:
      PolicyCanvasInspectorRow(label: "Binding", value: policyKind.kind)
    }
  }

  private func workflowField(
    _ policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> some View {
    PolicyCanvasInspectorField(label: "Workflow") {
      PolicyCanvasInspectorCommitTextField(
        label: "Workflow",
        placeholder: "default-task",
        value: policyKind.workflow ?? "",
        focusField: .workflow,
        focusedField: $focusedField,
        accessibilityIdentifier:
          HarnessMonitorAccessibility.policyCanvasInspectorField("workflow"),
        commit: { viewModel.commitSelectedWorkflow($0) }
      )
    }
  }

  private func workflowIDField(
    _ policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> some View {
    PolicyCanvasInspectorField(label: "Workflow id") {
      PolicyCanvasInspectorCommitTextField(
        label: "Workflow id",
        placeholder: "reviews_auto",
        value: policyKind.workflowId ?? "",
        focusField: .workflowID,
        focusedField: $focusedField,
        accessibilityIdentifier:
          HarnessMonitorAccessibility.policyCanvasInspectorField("workflow-id"),
        commit: { viewModel.commitSelectedWorkflowID($0) }
      )
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

  private func actionIDField(
    _ policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> some View {
    PolicyCanvasInspectorField(label: "Action id") {
      PolicyCanvasInspectorCommitTextField(
        label: "Action id",
        placeholder: "reviews.approve",
        value: policyKind.actionId ?? "",
        focusField: .actionID,
        focusedField: $focusedField,
        accessibilityIdentifier:
          HarnessMonitorAccessibility.policyCanvasInspectorField("action-id"),
        commit: { viewModel.commitSelectedActionID($0) }
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

  private func waitStepFields(
    _ policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      PolicyCanvasInspectorField(label: "Wait kind") {
        Picker("Wait kind", selection: selectedWaitConditionKindBinding(policyKind)) {
          Text("Timer").tag(TaskBoardPolicyWaitCondition.Kind.timer)
          Text("Event").tag(TaskBoardPolicyWaitCondition.Kind.event)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.policyCanvasInspectorField("wait-kind")
        )
      }
      if (policyKind.wait?.kind ?? .event) == .timer {
        PolicyCanvasInspectorField(label: "Duration") {
          PolicyCanvasInspectorCommitTextField(
            label: "Duration in seconds",
            placeholder: "900",
            value: String(policyKind.wait?.durationSeconds ?? 900),
            focusField: .waitDuration,
            focusedField: $focusedField,
            accessibilityIdentifier:
              HarnessMonitorAccessibility.policyCanvasInspectorField("wait-duration"),
            commit: { value in
              viewModel.commitSelectedWaitDuration(Int(value) ?? 900)
            }
          )
        }
      } else {
        PolicyCanvasInspectorField(label: "Event key") {
          PolicyCanvasInspectorCommitTextField(
            label: "Wait event key",
            placeholder: "reviews.checks_passed",
            value: policyKind.wait?.eventKey ?? "",
            focusField: .waitEventKey,
            focusedField: $focusedField,
            accessibilityIdentifier:
              HarnessMonitorAccessibility.policyCanvasInspectorField("wait-event-key"),
            commit: { viewModel.commitSelectedWaitEventKey($0) }
          )
        }
      }
      PolicyCanvasInspectorField(label: "Resume key") {
        PolicyCanvasInspectorCommitTextField(
          label: "Resume key",
          placeholder: "checks-ready",
          value: policyKind.resumeKey ?? "",
          focusField: .resumeKey,
          focusedField: $focusedField,
          accessibilityIdentifier:
            HarnessMonitorAccessibility.policyCanvasInspectorField("resume-key"),
          commit: { viewModel.commitSelectedResumeKey($0) }
        )
      }
    }
  }

  private func eventWaitField(
    _ policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> some View {
    PolicyCanvasInspectorField(label: "Event key") {
      PolicyCanvasInspectorCommitTextField(
        label: "Event key",
        placeholder: "reviews.checks_passed",
        value: policyKind.eventKey ?? "",
        focusField: .eventKey,
        focusedField: $focusedField,
        accessibilityIdentifier:
          HarnessMonitorAccessibility.policyCanvasInspectorField("event-key"),
        commit: { viewModel.commitSelectedEventKey($0) }
      )
    }
  }

  private func handoffField(
    _ policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> some View {
    PolicyCanvasInspectorField(label: "Handoff key") {
      PolicyCanvasInspectorCommitTextField(
        label: "Handoff key",
        placeholder: "next-handler",
        value: policyKind.handoffKey ?? "",
        focusField: .handoffKey,
        focusedField: $focusedField,
        accessibilityIdentifier:
          HarnessMonitorAccessibility.policyCanvasInspectorField("handoff-key"),
        commit: { viewModel.commitSelectedHandoffKey($0) }
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

  private func finishFields(
    _ policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      PolicyCanvasInspectorField(label: "Decision") {
        Picker("Finish behavior", selection: selectedDecisionBinding(policyKind)) {
          Text("Allow").tag("allow")
          Text("Deny").tag("deny")
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.policyCanvasInspectorField("finish-decision")
        )
      }
      reasonCodeField(policyKind)
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
