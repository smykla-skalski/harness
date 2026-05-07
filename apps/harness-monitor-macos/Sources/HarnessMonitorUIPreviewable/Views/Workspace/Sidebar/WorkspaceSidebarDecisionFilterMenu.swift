import HarnessMonitorKit
import SwiftUI

struct WorkspaceSidebarDecisionFilterToolbarItem: ToolbarContent {
  @Binding var selectedSeverities: Set<DecisionSeverity>
  let isEnabled: Bool

  init(
    selectedSeverities: Binding<Set<DecisionSeverity>>,
    isEnabled: Bool
  ) {
    _selectedSeverities = selectedSeverities
    self.isEnabled = isEnabled
  }

  var body: some ToolbarContent {
    ToolbarItem(placement: .automatic) {
      WorkspaceSidebarDecisionFilterMenu(
        selectedSeverities: $selectedSeverities,
        isEnabled: isEnabled
      )
      .disabled(!isEnabled)
    }

    ToolbarSpacer(.fixed, placement: .automatic)
  }
}

private struct WorkspaceSidebarDecisionFilterMenu: View {
  @Binding var selectedSeverities: Set<DecisionSeverity>
  let isEnabled: Bool

  init(
    selectedSeverities: Binding<Set<DecisionSeverity>>,
    isEnabled: Bool
  ) {
    _selectedSeverities = selectedSeverities
    self.isEnabled = isEnabled
  }

  private var hasActiveFilters: Bool {
    !selectedSeverities.isEmpty
  }

  private var selectedSeverityLabels: String {
    DecisionSeverity.sidebarOrdering
      .filter { selectedSeverities.contains($0) }
      .map(\.chipLabel)
      .joined(separator: ", ")
  }

  private var accessibilityValue: String {
    guard isEnabled else {
      return "Unavailable until the workspace has active decisions"
    }
    if hasActiveFilters {
      return "Filtered to \(selectedSeverityLabels)"
    }
    return "All severities"
  }

  private var helpText: String {
    isEnabled
      ? "Filter decisions by severity"
      : "Severity filters become available when the workspace has active decisions"
  }

  var body: some View {
    Menu {
      Button("All severities") {
        selectedSeverities = []
      }
      .disabled(!hasActiveFilters)
      .harnessMCPMenuItem(
        HarnessMonitorAccessibility.decisionsSidebarAllChip,
        label: "All severities",
        enabled: hasActiveFilters,
        pressAction: { selectedSeverities = [] }
      )

      Divider()

      ForEach(DecisionSeverity.sidebarOrdering, id: \.self) { severity in
        Button {
          toggle(severity)
        } label: {
          if selectedSeverities.contains(severity) {
            Label(severity.chipLabel, systemImage: "checkmark")
          } else {
            Text(severity.chipLabel)
          }
        }
        .harnessMCPMenuItem(
          HarnessMonitorAccessibility.decisionsSidebarSeverityChip(severity.rawValue),
          label: severity.chipLabel,
          pressAction: { toggle(severity) }
        )
      }
    } label: {
      Label(
        "Severity",
        systemImage: hasActiveFilters
          ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
      )
    }
    .help(helpText)
    .accessibilityLabel("Severity")
    .accessibilityValue(accessibilityValue)
    .accessibilityFrameMarker("\(HarnessMonitorAccessibility.workspaceDecisionFiltersMenu).frame")
    .harnessMCPButton(
      HarnessMonitorAccessibility.workspaceDecisionFiltersMenu,
      label: "Decision severity filters",
      value: accessibilityValue,
      enabled: isEnabled
    )
  }

  private func toggle(_ severity: DecisionSeverity) {
    var next = selectedSeverities
    if next.contains(severity) {
      next.remove(severity)
    } else {
      next.insert(severity)
    }
    selectedSeverities = next
  }
}

struct WorkspaceSidebarDecisionFilterStateMarker: View {
  let filters: DecisionsSidebarViewModel.FilterState
  let decisionScope: DecisionWorkspaceScope

  private var stateValue: String {
    let severities = filters.severities.map(\.rawValue).sorted().joined(separator: ",")
    return [
      "query=\(filters.query)",
      "scope=\(filters.scope.rawValue)",
      "severities=\(severities.isEmpty ? "all" : severities)",
      "visible=\(decisionScope.visibleCount)",
      "total=\(decisionScope.totalCount)",
    ].joined(separator: ", ")
  }

  var body: some View {
    if HarnessMonitorUITestEnvironment.searchMarkersEnabled {
      AccessibilityTextMarker(
        identifier: HarnessMonitorAccessibility.workspaceDecisionFilterState,
        text: stateValue
      )
    }
  }
}
