import HarnessMonitorKit
import SwiftUI

struct AgentsSidebarDecisionFilterToolbarItem: ToolbarContent {
  let selectedSeverities: Set<DecisionSeverity>
  let isEnabled: Bool
  let setSelectedSeverities: (Set<DecisionSeverity>) -> Void

  var body: some ToolbarContent {
    ToolbarItem(placement: .automatic) {
      AgentsSidebarDecisionFilterMenu(
        selectedSeverities: selectedSeverities,
        isEnabled: isEnabled,
        setSelectedSeverities: setSelectedSeverities
      )
      .disabled(!isEnabled)
    }
  }
}

private struct AgentsSidebarDecisionFilterMenu: View {
  let selectedSeverities: Set<DecisionSeverity>
  let isEnabled: Bool
  let setSelectedSeverities: (Set<DecisionSeverity>) -> Void

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
        setSelectedSeverities([])
      }
      .disabled(!hasActiveFilters)
      .accessibilityIdentifier(HarnessMonitorAccessibility.decisionsSidebarAllChip)

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
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.decisionsSidebarSeverityChip(severity.rawValue)
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
    .accessibilityIdentifier(HarnessMonitorAccessibility.agentsDecisionFiltersMenu)
    .accessibilityFrameMarker("\(HarnessMonitorAccessibility.agentsDecisionFiltersMenu).frame")
  }

  private func toggle(_ severity: DecisionSeverity) {
    var next = selectedSeverities
    if next.contains(severity) {
      next.remove(severity)
    } else {
      next.insert(severity)
    }
    setSelectedSeverities(next)
  }
}

struct AgentsSidebarDecisionFilterStateMarker: View {
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
        identifier: HarnessMonitorAccessibility.agentsDecisionFilterState,
        text: stateValue
      )
    }
  }
}
