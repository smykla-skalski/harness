import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

/// Scenario list section of the confidence panel. Collapsed by default so it
/// does not crowd the decision matrix; expanding it explains what scenarios are,
/// then lets the user add one, drop one, or reset to the seeded set, and routes a
/// row tap to "show path" via the shared focus-decision closure. The Add/Reset
/// actions live inside the expanded body so they never appear before the content
/// they act on, and Reset confirms first because it discards the user's set. The
/// rows are a resolved value so the section skips its body when only the spinner
/// or validation changes.
struct PolicyCanvasScenarioInspector: View {
  let rows: [PolicyCanvasScenarioRowModel]
  let isEvaluating: Bool
  let focusDecision: @MainActor ([String]) -> Void
  let addScenario: @MainActor () -> Void
  let editScenario: @MainActor (String) -> Void
  let deleteScenario: @MainActor (String) -> Void
  let resetScenarios: @MainActor () -> Void

  @State private var isExpanded = false
  @State private var isConfirmingReset = false

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
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .accessibilityLabel("Scenarios, \(rows.count)")
    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    .accessibilityHint("Add or review test inputs for your policy")
  }

  @ViewBuilder private var content: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Test inputs that show how your policy decides a specific case")
        .scaledFont(.caption2)
        .foregroundStyle(PolicyCanvasVisualStyle.tertiaryText)
        .fixedSize(horizontal: false, vertical: true)

      actions

      if rows.isEmpty {
        Text(isEvaluating ? "Evaluating scenarios\u{2026}" : "No scenarios yet - add one to start")
          .scaledFont(.caption)
          .foregroundStyle(PolicyCanvasVisualStyle.tertiaryText)
      } else {
        // No inner scroll or fixed cap: the confidence pane owns one scroll view,
        // so a long scenario list flows with the decisions and replay instead of
        // scrolling inside a 180pt window while the pane has empty room below.
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
    }
    .padding(.horizontal, 12)
    .padding(.bottom, 10)
  }

  private var actions: some View {
    HStack(spacing: 8) {
      // Bordered chips, not bare tinted text: a flat colored word reads as a
      // label, so the round-2 panel left "Add scenario"/"Reset" looking
      // unclickable. The bezel is the affordance.
      Button("Add scenario", action: addScenario)
        .scaledFont(.caption.weight(.semibold))
        .harnessActionButtonStyle(variant: .bordered, tint: PolicyCanvasVisualStyle.readyTint)
        .controlSize(.small)
        .help("Add a scenario to test how the policy decides a specific case")
        .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasScenarioAddButton)

      Button("Reset") {
        isConfirmingReset = true
      }
      .scaledFont(.caption.weight(.medium))
      .harnessActionButtonStyle(variant: .bordered)
      .controlSize(.small)
      .help("Remove your scenarios and restore the default set")
      .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasScenarioResetButton)

      Spacer(minLength: 0)
    }
    .confirmationDialog(
      "Reset scenarios to the default set?",
      isPresented: $isConfirmingReset,
      titleVisibility: .visible
    ) {
      Button("Reset scenarios", role: .destructive, action: resetScenarios)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This removes any scenarios you added and restores the seeded set")
    }
  }
}
