import HarnessMonitorKit
import SwiftUI
import HarnessMonitorPolicyCanvasAlgorithms

/// Ordered checks editor for an `evidence_check` node. The engine evaluates
/// checks top to bottom and fails on the first whose predicate does not hold,
/// emitting that check's fail reason code - so the list order is the failure
/// priority and the reason codes are exactly what a downstream fan-in branch
/// routes on. Each check exposes its evidence field, the predicate it must
/// satisfy to pass, and the reason code emitted on failure; reorder and remove
/// controls live in the per-check header. Module-internal so the dispatch
/// helper in `PolicyCanvasInspectorNodePolicyControls` can construct it.
struct PolicyCanvasInspectorEvidenceChecksControl: View {
  let viewModel: PolicyCanvasViewModel
  let field: PolicyInspectorField
  let checks: [TaskBoardPolicyEvidenceCheck]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(checks.enumerated()), id: \.offset) { index, check in
        PolicyCanvasInspectorEvidenceCheckRow(
          viewModel: viewModel,
          check: check,
          index: index,
          checkCount: checks.count
        )
      }

      HStack(spacing: 8) {
        Image(systemName: "arrow.turn.down.right")
          .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
        Text("Checks run top to bottom; the first failing one sets the reason code.")
          .scaledFont(.caption)
          .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
      }

      Button {
        viewModel.addSelectedEvidenceCheck()
      } label: {
        Label("Add check", systemImage: "plus")
      }
      .buttonStyle(.glass)
      .controlSize(.small)
    }
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.policyCanvasInspectorField(field.accessibilityKey)
    )
  }
}

struct PolicyCanvasInspectorEvidenceCheckRow: View {
  let viewModel: PolicyCanvasViewModel
  let check: TaskBoardPolicyEvidenceCheck
  let index: Int
  let checkCount: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      labeledControl("Field") { fieldPicker }
      labeledControl("Passes") { predicatePicker }
      labeledControl("On fail") { failReasonCodePicker }
    }
    .padding(.vertical, 2)
  }

  private var header: some View {
    HStack(spacing: 8) {
      Text("Check \(index + 1)")
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(PolicyCanvasVisualStyle.primaryText)

      Spacer(minLength: 0)

      reorderButton(
        systemImage: "chevron.up",
        label: "Move check \(index + 1) up",
        disabled: index == 0,
        destination: index - 1
      )
      reorderButton(
        systemImage: "chevron.down",
        label: "Move check \(index + 1) down",
        disabled: index == checkCount - 1,
        destination: index + 1
      )

      if checkCount > 1 {
        Button {
          viewModel.removeSelectedEvidenceCheck(at: index)
        } label: {
          Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
        .accessibilityLabel("Remove check \(index + 1)")
      }
    }
  }

  private func reorderButton(
    systemImage: String,
    label: String,
    disabled: Bool,
    destination: Int
  ) -> some View {
    Button {
      viewModel.moveSelectedEvidenceCheck(from: index, to: destination)
    } label: {
      Image(systemName: systemImage)
    }
    .buttonStyle(.borderless)
    .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
    .disabled(disabled)
    .accessibilityLabel(label)
  }

  private func labeledControl(
    _ caption: String,
    @ViewBuilder content: () -> some View
  ) -> some View {
    HStack(spacing: 8) {
      Text(caption)
        .scaledFont(.caption)
        .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
        .frame(width: 56, alignment: .leading)
      content()
    }
  }

  private var fieldPicker: some View {
    Picker(
      "Check \(index + 1) field",
      selection: Binding(
        get: { check.field },
        set: { viewModel.commitSelectedEvidenceCheckField($0, at: index) }
      )
    ) {
      ForEach(TaskBoardPolicyEvidenceField.allCases, id: \.self) { evidenceField in
        Text(evidenceField.policyCanvasTitle).tag(evidenceField)
      }
    }
    .labelsHidden()
    .pickerStyle(.menu)
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.policyCanvasInspectorField("evidence-check-field-\(index)")
    )
  }

  private var predicatePicker: some View {
    Picker(
      "Check \(index + 1) predicate",
      selection: Binding(
        get: { check.pass.predicate },
        set: { viewModel.commitSelectedEvidenceCheckPredicate($0, at: index) }
      )
    ) {
      ForEach(TaskBoardPolicyEvidencePredicateValue.allCases, id: \.self) { predicate in
        Text(predicate.policyCanvasTitle).tag(predicate)
      }
    }
    .labelsHidden()
    .pickerStyle(.menu)
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.policyCanvasInspectorField("evidence-check-predicate-\(index)")
    )
  }

  private var failReasonCodePicker: some View {
    Picker(
      "Check \(index + 1) fail reason code",
      selection: Binding(
        get: { check.failReasonCode },
        set: { viewModel.commitSelectedEvidenceCheckFailReasonCode($0, at: index) }
      )
    ) {
      ForEach(PolicyCanvasReasonCode.ordered, id: \.self) { code in
        Text(PolicyCanvasReasonCode.displayName(code)).tag(code)
      }
    }
    .labelsHidden()
    .pickerStyle(.menu)
    .help("The reason code the engine emits when this check fails")
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.policyCanvasInspectorField("evidence-check-reason-\(index)")
    )
  }
}
