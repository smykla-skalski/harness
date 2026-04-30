import HarnessMonitorKit
import SwiftUI

struct AgentsSidebarDecisionSection: View {
  @Binding var selection: WorkspaceSelection
  @Binding var decisionFilters: DecisionsSidebarViewModel.FilterState
  let scope: DecisionWorkspaceScope
  let currentSessionID: String?
  let currentSessionTitle: String?
  let fontScale: CGFloat
  @Binding var decisionQuery: String
  @Binding var decisionFilterExpanded: Bool
  @Binding var decisionSeveritiesCSV: String
  @Binding var decisionSearchScopeRaw: String
  let acpPayload: (Decision) -> AcpPermissionDecisionPayload?
  let lastMessageAt: (Decision) -> Date?

  private var rowPadding: CGFloat {
    HarnessMonitorTheme.spacingXS * fontScale
  }

  private var selectedSeverities: Set<DecisionSeverity> {
    Set(
      decisionSeveritiesCSV
        .split(separator: ",")
        .compactMap { DecisionSeverity(rawValue: String($0)) }
    )
  }

  private var decisionSearchScope: DecisionsSidebarSearchScope {
    DecisionsSidebarSearchScope(rawValue: decisionSearchScopeRaw) ?? .summary
  }

  private var activeSearchSummary: String {
    scope.scopeDescription
  }

  private var selectedSeverityCount: Int {
    selectedSeverities.count
  }

  var body: some View {
    Section("Decisions") {
      decisionDeskRow
      decisionSearchRow
        .listRowSeparator(.hidden)
      if decisionFilterExpanded {
        decisionSeverityRow
          .listRowSeparator(.hidden)
      }
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
    .onAppear {
      applyExternalDecisionFilters()
      publishDecisionFilters()
    }
    .onChange(of: decisionQuery) { _, _ in
      publishDecisionFilters()
    }
    .onChange(of: decisionSeveritiesCSV) { _, _ in
      publishDecisionFilters()
    }
    .onChange(of: decisionSearchScopeRaw) { _, _ in
      publishDecisionFilters()
    }
    .onChange(of: decisionFilters) { _, newValue in
      applyExternalDecisionFilters(newValue)
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
      }
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      Text(scope.countLabel)
        .scaledFont(.caption.monospacedDigit())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, rowPadding)
    .tag(WorkspaceSelection.decisions(sessionID: currentSessionID))
  }

  private var decisionSearchRow: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        TextField(decisionSearchScope.label, text: $decisionQuery)
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier(HarnessMonitorAccessibility.decisionsSidebarSearch)
        decisionSearchScopeMenu
        decisionFilterToggle
      }

      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        HStack(spacing: HarnessMonitorTheme.spacingXS) {
          TextField(decisionSearchScope.label, text: $decisionQuery)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier(HarnessMonitorAccessibility.decisionsSidebarSearch)
          decisionFilterToggle
        }

        decisionSearchScopeMenu
      }
    }
    .padding(.vertical, HarnessMonitorTheme.spacingXS)
  }

  private var decisionFilterToggle: some View {
    let systemName =
      decisionFilterExpanded
      ? "line.3.horizontal.decrease.circle.fill"
      : "line.3.horizontal.decrease.circle"
    return Button {
      decisionFilterExpanded.toggle()
    } label: {
      Label(
        selectedSeverityCount > 0 ? "Filters \(selectedSeverityCount)" : "Filters",
        systemImage: systemName
      )
      .labelStyle(.titleAndIcon)
      .foregroundStyle(
        decisionFilterExpanded ? HarnessMonitorTheme.accent : HarnessMonitorTheme.secondaryInk
      )
    }
    .buttonStyle(.borderless)
    .accessibilityLabel(decisionFilterExpanded ? "Hide filters" : "Show filters")
    .accessibilityIdentifier(HarnessMonitorAccessibility.decisionsSidebarFilterToggle)
  }

  private var decisionSearchScopeMenu: some View {
    Menu {
      Picker("Search scope", selection: $decisionSearchScopeRaw) {
        ForEach(DecisionsSidebarSearchScope.allCases) { scope in
          Label(scope.label, systemImage: scope.systemImage)
            .tag(scope.rawValue)
        }
      }
    } label: {
      Label(decisionSearchScope.label, systemImage: decisionSearchScope.systemImage)
        .labelStyle(.titleAndIcon)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
    .menuStyle(.borderlessButton)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityLabel("Search scope — \(decisionSearchScope.label)")
    .accessibilityIdentifier(HarnessMonitorAccessibility.decisionsSidebarSearchScopeMenu)
  }

  private var decisionSeverityRow: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        decisionAllChip
        ForEach(DecisionSeverity.sidebarOrdering, id: \.self) { severity in
          decisionSeverityChip(severity)
        }
      }
      .padding(.vertical, 1)
    }
    .contentMargins(.horizontal, HarnessMonitorTheme.spacingXS, for: .scrollContent)
    .scrollClipDisabled()
  }

  private var decisionAllChip: some View {
    let isActive = selectedSeverities.isEmpty
    return Button {
      setSelectedSeverities([])
    } label: {
      Text("All")
        .scaledFont(.caption.weight(.semibold))
    }
    .harnessFilterChipButtonStyle(isSelected: isActive)
    .accessibilityIdentifier(HarnessMonitorAccessibility.decisionsSidebarAllChip)
    .accessibilityValue(isActive ? "selected" : "not selected")
  }

  private func decisionSeverityChip(_ severity: DecisionSeverity) -> some View {
    let isActive = selectedSeverities.contains(severity)
    return Button {
      var next = selectedSeverities
      if next.contains(severity) {
        next.remove(severity)
      } else {
        next.insert(severity)
      }
      setSelectedSeverities(next)
    } label: {
      Text(severity.chipLabel)
        .scaledFont(.caption.weight(.semibold))
        .lineLimit(1)
    }
    .harnessFilterChipButtonStyle(isSelected: isActive)
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.decisionsSidebarSeverityChip(severity.rawValue)
    )
    .accessibilityLabel(severity.chipLabel)
    .accessibilityValue(isActive ? "selected" : "not selected")
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

  private func setSelectedSeverities(_ newValue: Set<DecisionSeverity>) {
    decisionSeveritiesCSV = newValue.map(\.rawValue).sorted().joined(separator: ",")
  }

  private func clearFilters() {
    decisionQuery = ""
    decisionSeveritiesCSV = ""
    decisionSearchScopeRaw = DecisionsSidebarSearchScope.summary.rawValue
  }

  private func publishDecisionFilters() {
    decisionFilters = DecisionsSidebarViewModel.FilterState(
      query: decisionQuery,
      severities: selectedSeverities,
      scope: decisionSearchScope
    )
  }

  private func applyExternalDecisionFilters(
    _ incoming: DecisionsSidebarViewModel.FilterState? = nil
  ) {
    let source = incoming ?? decisionFilters
    if decisionQuery != source.query {
      decisionQuery = source.query
    }
    if selectedSeverities != source.severities {
      setSelectedSeverities(source.severities)
    }
    if decisionSearchScopeRaw != source.scope.rawValue {
      decisionSearchScopeRaw = source.scope.rawValue
    }
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
