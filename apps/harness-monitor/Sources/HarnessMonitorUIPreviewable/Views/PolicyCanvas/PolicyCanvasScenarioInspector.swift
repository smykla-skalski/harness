import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

/// Scenario list section of the confidence panel. Collapsed by default so it does
/// not crowd the decision matrix; expanded it lists each named scenario with its
/// current verdict, lets the user drop a scenario or reset to the seeded set, and
/// routes a row tap to "show path" via the shared focus-decision closure. The rows
/// are a resolved value so the section skips its body when only the spinner or
/// validation changes.
struct PolicyCanvasScenarioInspector: View {
  let rows: [PolicyCanvasScenarioRowModel]
  let isEvaluating: Bool
  let focusDecision: @MainActor ([String]) -> Void
  let addScenario: @MainActor () -> Void
  let editScenario: @MainActor (String) -> Void
  let deleteScenario: @MainActor (String) -> Void
  let resetScenarios: @MainActor () -> Void

  @State private var isExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Rectangle()
        .fill(PolicyCanvasVisualStyle.separator)
        .frame(height: 1)
      header
      if isExpanded {
        content
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasScenarioInspector)
  }

  private var header: some View {
    HStack(spacing: 8) {
      Button {
        isExpanded.toggle()
      } label: {
        HStack(spacing: 6) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .scaledFont(.caption2.weight(.semibold))
          Text("Scenarios")
            .scaledFont(.caption.weight(.semibold))
          Text("\(rows.count)")
            .scaledFont(.caption2)
            .foregroundStyle(PolicyCanvasVisualStyle.tertiaryText)
          if isEvaluating {
            ProgressView().controlSize(.mini)
          }
        }
        .contentShape(Rectangle())
      }
      .harnessPlainButtonStyle()
      .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)

      Spacer(minLength: 8)

      Button("Add", action: addScenario)
        .scaledFont(.caption2.weight(.semibold))
        .harnessPlainButtonStyle()
        .foregroundStyle(PolicyCanvasVisualStyle.readyTint)
        .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasScenarioAddButton)

      Button("Reset", action: resetScenarios)
        .scaledFont(.caption2.weight(.medium))
        .harnessPlainButtonStyle()
        .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
        .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasScenarioResetButton)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  @ViewBuilder private var content: some View {
    if rows.isEmpty {
      Text(isEvaluating ? "Evaluating scenarios" : "No scenarios yet")
        .scaledFont(.caption)
        .foregroundStyle(PolicyCanvasVisualStyle.tertiaryText)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(rows) { row in
            PolicyCanvasScenarioRow(
              row: row,
              focusDecision: focusDecision,
              editScenario: editScenario,
              deleteScenario: deleteScenario
            )
          }
        }
      }
      .frame(maxHeight: 180)
      .padding(.bottom, 6)
    }
  }
}
