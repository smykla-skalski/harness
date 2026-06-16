import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import HarnessMonitorPolicyModels
import SwiftUI

/// Ordered-cases editor for a `switch` node. Each arm is one output port that
/// routes when its evidence field satisfies its predicate; the implicit
/// "default" port runs when no case matches. Arms are addressed by index and
/// commits re-resolve the selected node, so the row views stay value types.
/// Extracted from `PolicyCanvasInspectorNodePolicyControls` on touch to keep
/// that file under the size cap; module-internal so the dispatch helper there
/// can construct it.
struct PolicyCanvasInspectorSwitchCasesControl: View {
  let viewModel: PolicyCanvasViewModel
  let field: PolicyInspectorField
  let arms: [PolicySwitchArm]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(arms.enumerated()), id: \.offset) { index, arm in
        PolicyCanvasInspectorSwitchCaseRow(
          viewModel: viewModel,
          arm: arm,
          index: index,
          canRemove: arms.count > 1
        )
      }

      HStack(spacing: 8) {
        Image(systemName: "arrow.turn.down.right")
          .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
        Text("Default runs when no cases match.")
          .scaledFont(.caption)
          .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
      }

      Button {
        viewModel.addSelectedSwitchArm()
      } label: {
        Label("Add case", systemImage: "plus")
      }
      .harnessGlassButtonStyle(controlSize: .small)
    }
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.policyCanvasInspectorField(field.accessibilityKey)
    )
  }
}

struct PolicyCanvasInspectorSwitchCaseRow: View {
  let viewModel: PolicyCanvasViewModel
  let arm: PolicySwitchArm
  let index: Int
  let canRemove: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Text("Case \(index + 1)")
          .scaledFont(.caption.weight(.semibold))
          .foregroundStyle(PolicyCanvasVisualStyle.primaryText)

        Spacer(minLength: 0)

        if canRemove {
          Button {
            viewModel.removeSelectedSwitchArm(at: index)
          } label: {
            Image(systemName: "trash")
          }
          .buttonStyle(.borderless)
          .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
          .accessibilityLabel("Remove case \(index + 1)")
        }
      }

      HStack(spacing: 8) {
        Picker(
          "Case \(index + 1) evidence",
          selection: Binding(
            get: { arm.field },
            set: { viewModel.commitSelectedSwitchArmField($0, at: index) }
          )
        ) {
          ForEach(PolicyEvidenceField.allCases, id: \.self) { evidenceField in
            Text(evidenceField.policyCanvasTitle).tag(evidenceField)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)

        Picker(
          "Case \(index + 1) condition",
          selection: Binding(
            get: { arm.predicate },
            set: { viewModel.commitSelectedSwitchArmPredicate($0, at: index) }
          )
        ) {
          ForEach(PolicyEvidencePredicate.allCases, id: \.self) { predicate in
            Text(predicate.policyCanvasTitle).tag(predicate)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
      }
    }
    .padding(.vertical, 2)
  }
}
