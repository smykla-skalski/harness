import HarnessMonitorKit
import SwiftUI

/// Decisions window sidebar. Search + severity chip filters at the top, ScrollView + LazyVStack
/// body (never List per memory `feedback_sidebar_no_list.md`), one section per session, severity
/// chip next to each row. Selection writes back through a `Binding<String?>` so the detail
/// column can render the chosen decision by id.
public struct DecisionsSidebar: View {
  @Binding private var selectedDecisionID: String?
  @Binding private var filters: DecisionsSidebarViewModel.FilterState
  private let decisions: [Decision]
  private let store: HarnessMonitorStore?

  @State private var query: String = ""

  @AppStorage("harness.decisions.sidebar.filterExpanded")
  private var filterExpanded: Bool = true

  @AppStorage("harness.decisions.sidebar.severitiesCSV")
  private var severitiesCSV: String = ""

  @AppStorage("harness.decisions.sidebar.searchScope")
  private var searchScopeRaw: String = DecisionsSidebarSearchScope.summary.rawValue

  @Environment(\.fontScale)
  private var fontScale

  public init(
    decisions: [Decision] = [],
    selection: Binding<String?> = .constant(nil),
    filters: Binding<DecisionsSidebarViewModel.FilterState> = .constant(
      .init(query: "", severities: [], scope: .summary)
    ),
    store: HarnessMonitorStore? = nil
  ) {
    self.decisions = decisions
    self.store = store
    _selectedDecisionID = selection
    _filters = filters
  }

  private var selectedSeverities: Set<DecisionSeverity> {
    Set(
      severitiesCSV
        .split(separator: ",")
        .compactMap { DecisionSeverity(rawValue: String($0)) }
    )
  }

  private var searchScope: DecisionsSidebarSearchScope {
    DecisionsSidebarSearchScope(rawValue: searchScopeRaw) ?? .summary
  }

  private func setSelectedSeverities(_ newValue: Set<DecisionSeverity>) {
    severitiesCSV = newValue.map(\.rawValue).sorted().joined(separator: ",")
  }

  private var visibleSnapshot: DecisionsSidebarViewModel.VisibleSnapshot {
    DecisionsSidebarViewModel.visibleSnapshot(
      decisions: decisions,
      filters: .init(
        query: query,
        severities: selectedSeverities,
        scope: searchScope
      )
    )
  }

  private func lastAcpMessageAt(
    for decision: Decision
  ) -> Date? {
    store?.acpPermissionLastSignalAt(sessionID: decision.sessionID)
  }

  private func acpPayload(
    for decision: Decision
  ) -> AcpPermissionDecisionPayload? {
    guard decision.ruleID == AcpPermissionDecisionPayload.ruleID else {
      return nil
    }
    return store?.acpPermissionDecisionPayload(for: decision.id)
      ?? AcpPermissionDecisionPayload.decode(from: decision)
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      content
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.decisionsSidebar)
    .onAppear {
      applyExternalFilters()
      publishFilters()
    }
    .onChange(of: query) { _, _ in
      publishFilters()
    }
    .onChange(of: severitiesCSV) { _, _ in
      publishFilters()
    }
    .onChange(of: searchScopeRaw) { _, _ in
      publishFilters()
    }
    .onChange(of: filters) { _, newValue in
      applyExternalFilters(newValue)
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      searchRow
      if filterExpanded {
        severityChipRow
          .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .padding(HarnessMonitorTheme.spacingMD)
    .animation(.snappy(duration: 0.18), value: filterExpanded)
  }

  private var searchRow: some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      TextField(searchScope.label, text: $query)
        .textFieldStyle(.roundedBorder)
        .accessibilityIdentifier(HarnessMonitorAccessibility.decisionsSidebarSearch)
      scopeMenu
      filterToggleButton
    }
  }

  private var filterToggleButton: some View {
    let systemName: String
    if filterExpanded {
      systemName = "line.3.horizontal.decrease.circle.fill"
    } else {
      systemName = "line.3.horizontal.decrease.circle"
    }
    return Button {
      filterExpanded.toggle()
    } label: {
      Image(systemName: systemName)
        .imageScale(.large)
        .foregroundStyle(
          filterExpanded ? HarnessMonitorTheme.accent : HarnessMonitorTheme.secondaryInk
        )
    }
    .buttonStyle(.borderless)
    .accessibilityLabel(filterExpanded ? "Hide filters" : "Show filters")
    .accessibilityIdentifier(HarnessMonitorAccessibility.decisionsSidebarFilterToggle)
  }

  private var scopeMenu: some View {
    Menu {
      Picker("Search scope", selection: $searchScopeRaw) {
        ForEach(DecisionsSidebarSearchScope.allCases) { scope in
          Label(scope.label, systemImage: scope.systemImage)
            .tag(scope.rawValue)
        }
      }
    } label: {
      Image(systemName: searchScope.systemImage)
        .imageScale(.medium)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityLabel("Search scope — \(searchScope.label)")
    .accessibilityIdentifier(HarnessMonitorAccessibility.decisionsSidebarSearchScopeMenu)
  }

  private func publishFilters() {
    filters = DecisionsSidebarViewModel.FilterState(
      query: query,
      severities: selectedSeverities,
      scope: searchScope
    )
  }

  private func applyExternalFilters(_ incoming: DecisionsSidebarViewModel.FilterState? = nil) {
    let source = incoming ?? filters
    if query != source.query {
      query = source.query
    }
    if selectedSeverities != source.severities {
      setSelectedSeverities(source.severities)
    }
    if searchScopeRaw != source.scope.rawValue {
      searchScopeRaw = source.scope.rawValue
    }
  }

  private var severityChipRow: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        allChip
        ForEach(DecisionSeverity.sidebarOrdering, id: \.self) { severity in
          severityChip(severity)
        }
      }
      .fixedSize(horizontal: true, vertical: false)
      .padding(.vertical, 1)
    }
  }

  private var allChip: some View {
    let isActive = selectedSeverities.isEmpty
    return Button {
      setSelectedSeverities([])
    } label: {
      Text("All")
        .scaledFont(.caption.bold())
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, HarnessMonitorTheme.pillPaddingH)
        .padding(.vertical, HarnessMonitorTheme.pillPaddingV)
        .background(
          Capsule().fill(isActive ? HarnessMonitorTheme.accent : Color.clear)
        )
        .overlay(
          Capsule().strokeBorder(
            HarnessMonitorTheme.accent.opacity(isActive ? 0 : 0.35),
            lineWidth: 1
          )
        )
        .foregroundStyle(
          isActive ? HarnessMonitorTheme.onContrast : HarnessMonitorTheme.secondaryInk
        )
        .contentShape(Capsule())
    }
    .harnessFilterChipButtonStyle(isSelected: isActive)
    .accessibilityIdentifier(HarnessMonitorAccessibility.decisionsSidebarAllChip)
    .accessibilityValue(isActive ? "selected" : "not selected")
  }

  private func severityChip(_ severity: DecisionSeverity) -> some View {
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
        .scaledFont(.caption)
        .fixedSize(horizontal: true, vertical: false)
        .lineLimit(1)
        .padding(.horizontal, HarnessMonitorTheme.pillPaddingH)
        .padding(.vertical, HarnessMonitorTheme.pillPaddingV)
        .background(
          Capsule().fill(isActive ? severity.chipColor : Color.clear)
        )
        .overlay(
          Capsule().strokeBorder(
            severity.chipColor.opacity(isActive ? 0 : 0.35),
            lineWidth: 1
          )
        )
        .foregroundStyle(
          isActive ? HarnessMonitorTheme.onContrast : severity.chipColor.opacity(0.85)
        )
        .contentShape(Capsule())
    }
    .harnessFilterChipButtonStyle(isSelected: isActive)
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.decisionsSidebarSeverityChip(severity.rawValue)
    )
    .accessibilityValue(isActive ? "selected" : "not selected")
  }

  @ViewBuilder private var content: some View {
    let visibleGroups = visibleSnapshot.groups
    if visibleGroups.isEmpty {
      emptyState
    } else {
      ScrollView {
        LazyVStack(
          alignment: .leading,
          spacing: HarnessMonitorTheme.spacingMD,
          pinnedViews: [.sectionHeaders]
        ) {
          ForEach(visibleGroups, id: \.sessionID) { group in
            sessionSection(group)
          }
        }
        .padding(.vertical, HarnessMonitorTheme.spacingSM)
      }
    }
  }

  private var emptyState: some View {
    VStack(spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: "bell.slash")
        .font(.title2)
        .foregroundStyle(.secondary)
      Text("No decisions match")
        .scaledFont(.body)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }

  private func sessionSection(
    _ group: DecisionsSidebarViewModel.SessionGroup
  ) -> some View {
    Section {
      ForEach(group.decisions, id: \.id) { decision in
        DecisionRow(
          decision: decision,
          isSelected: selectedDecisionID == decision.id,
          fontScale: fontScale,
          acpPayload: acpPayload(for: decision),
          lastMessageAt: lastAcpMessageAt(for: decision)
        ) {
          selectedDecisionID = decision.id
        }
      }
    } header: {
      sessionHeader(group)
    }
  }

  private func sessionHeader(
    _ group: DecisionsSidebarViewModel.SessionGroup
  ) -> some View {
    HStack {
      Text(group.sessionID ?? "No session")
        .scaledFont(.caption)
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
      Spacer()
      Text("\(group.decisions.count)")
        .scaledFont(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .padding(.vertical, HarnessMonitorTheme.spacingXS)
    .background(.background)
  }
}
