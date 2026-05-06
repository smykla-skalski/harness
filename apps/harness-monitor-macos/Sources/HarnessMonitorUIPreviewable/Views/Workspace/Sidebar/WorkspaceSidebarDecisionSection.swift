import HarnessMonitorKit
import SwiftUI

struct WorkspaceSidebarDecisionSection: View {
  @Binding var selection: WorkspaceSelection
  @Binding var decisionFilters: DecisionsSidebarViewModel.FilterState
  let scope: DecisionWorkspaceScope
  let currentSessionID: String?
  let currentSessionTitle: String?
  let fontScale: CGFloat
  let acpPayload: (Decision) -> AcpPermissionDecisionPayload?
  let lastMessageAt: (Decision) -> Date?

  private var rowPadding: CGFloat {
    HarnessMonitorTheme.spacingXS * fontScale
  }

  private var activeSearchSummary: String {
    scope.scopeDescription
  }

  private var decisionDeskAccessibilityValue: String {
    if scope.hasActiveFilters {
      return "\(scope.resultSummary). \(activeSearchSummary)"
    }
    return scope.resultSummary
  }

  private var decisionDeskAccessibilityLabel: String {
    "Decision Desk. \(decisionDeskAccessibilityValue)"
  }

  var body: some View {
    Section("Decisions") {
      decisionDeskRow
      if scope.groups.isEmpty {
        decisionEmptyState
          .listRowSeparator(.hidden)
      } else {
        ForEach(scope.groups, id: \.sessionID) { group in
          decisionSessionHeader(group)
            .listRowSeparator(.hidden)
          ForEach(group.decisions, id: \.id) { decision in
            DecisionRow(
              decision: decision,
              isSelected: selection.decisionID == decision.id,
              fontScale: fontScale,
              acpPayload: acpPayload(decision),
              lastMessageAt: lastMessageAt(decision)
            ) {
              selection = .decision(sessionID: decision.sessionID, decisionID: decision.id)
            }
            .tag(
              WorkspaceSelection.decision(
                sessionID: decision.sessionID,
                decisionID: decision.id
              )
            )
            .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
            .listRowSeparator(.hidden)
          }
        }
      }
    }
  }

  private var decisionDeskRow: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: "bell.badge")
        .foregroundStyle(HarnessMonitorTheme.accent)
      VStack(alignment: .leading, spacing: 2) {
        Text("Decision Desk")
          .scaledFont(.body.weight(.semibold))
        Text(scope.resultSummary)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        if scope.hasActiveFilters {
          Text(activeSearchSummary)
            .scaledFont(.caption2.weight(.medium))
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      Text(scope.countLabel)
        .scaledFont(.caption.monospacedDigit())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, rowPadding)
    .tag(WorkspaceSelection.decisions(sessionID: currentSessionID))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(decisionDeskAccessibilityLabel)
    .harnessMCPTab(
      HarnessMonitorAccessibility.workspaceDecisionDesk,
      label: decisionDeskAccessibilityLabel,
      value: decisionDeskAccessibilityValue,
      pressAction: {
        selection = .decisions(sessionID: currentSessionID)
      }
    )
  }

  private var decisionEmptyState: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text(scope.emptyStateTitle)
        .scaledFont(.caption.weight(.semibold))
      Text(scope.emptyStateDescription)
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .fixedSize(horizontal: false, vertical: true)
      if scope.hasActiveFilters {
        Button("Clear filters") {
          clearFilters()
        }
        .buttonStyle(.link)
        .scaledFont(.caption.weight(.semibold))
        .harnessMCPButton(
          HarnessMonitorAccessibility.workspaceDecisionClearFiltersButton,
          label: "Clear decision filters",
          value: activeSearchSummary,
          pressAction: clearFilters
        )
        Text(activeSearchSummary)
          .scaledFont(.caption2)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
  }

  private func decisionSessionHeader(
    _ group: DecisionsSidebarViewModel.SessionGroup
  ) -> some View {
    HStack {
      Text(sessionHeading(for: group.sessionID))
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      Spacer()
      Text("\(group.decisions.count)")
        .scaledFont(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingXS)
    .padding(.top, HarnessMonitorTheme.spacingSM)
  }

  private func clearFilters() {
    decisionFilters = DecisionsSidebarViewModel.FilterState(
      query: "",
      severities: [],
      scope: .summary
    )
  }

  private func sessionHeading(for sessionID: String?) -> String {
    guard let sessionID = normalizedValue(sessionID) else {
      return "Shared context"
    }

    if sessionID == currentSessionID {
      return normalizedValue(currentSessionTitle) ?? "Current session"
    }

    let hasStructuredID = sessionID.contains("-") || sessionID.contains("_")
    if let trailingToken = trailingSessionToken(from: sessionID), hasStructuredID {
      return "\(trailingToken.capitalized) session"
    }
    return "Session \(sessionID.suffix(6))"
  }

  private func normalizedValue(_ value: String?) -> String? {
    guard let value else {
      return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func trailingSessionToken(from sessionID: String) -> String? {
    sessionID
      .split(whereSeparator: { $0 == "-" || $0 == "_" })
      .last
      .map(String.init)
  }
}
