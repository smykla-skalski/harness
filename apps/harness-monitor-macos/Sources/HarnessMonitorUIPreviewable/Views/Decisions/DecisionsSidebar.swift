import HarnessMonitorKit
import SwiftUI

/// workspace window sidebar. Search + severity chip filters at the top, ScrollView + LazyVStack
/// body (never List per memory `feedback_sidebar_no_list.md`), one section per session, severity
/// chip next to each row. Selection writes back through a `Binding<String?>` so the detail
/// column can render the chosen decision by id.
public struct DecisionsSidebar: View {
  @Binding var selectedDecisionID: String?
  @Binding var filters: DecisionsSidebarViewModel.FilterState
  let decisions: [Decision]
  let decisionsByIDOverride: [String: Decision]?
  let decisionItemsOverride: [DecisionPresentationSnapshot]?
  let decisionsRevision: UInt64
  let presentationOverride: DecisionsSidebarPresentation?
  let store: HarnessMonitorStore?

  @State private var query: String = ""
  @State private var presentationWorker = DecisionsSidebarPresentationWorker()
  @State private var cachedPresentation = DecisionsSidebarPresentation.empty
  @State private var cachedDecisionsByID: [String: Decision] = [:]
  @State private var presentationGeneration: UInt64 = 0

  @AppStorage("harness.decisions.sidebar.filterExpanded")
  var filterExpanded: Bool = true

  @AppStorage("harness.decisions.sidebar.severitiesCSV")
  var severitiesCSV: String = ""

  @AppStorage("harness.decisions.sidebar.searchScope")
  var searchScopeRaw: String = DecisionsSidebarSearchScope.summary.rawValue

  @Environment(\.fontScale)
  var fontScale

  public init(
    decisions: [Decision] = [],
    decisionsByID: [String: Decision]? = nil,
    decisionItems: [DecisionPresentationSnapshot]? = nil,
    decisionsRevision: UInt64 = 0,
    presentation: DecisionsSidebarPresentation? = nil,
    selection: Binding<String?> = .constant(nil),
    filters: Binding<DecisionsSidebarViewModel.FilterState> = .constant(
      .init(query: "", severities: [], scope: .summary)
    ),
    store: HarnessMonitorStore? = nil
  ) {
    self.decisions = decisions
    decisionsByIDOverride = decisionsByID
    decisionItemsOverride = decisionItems
    self.decisionsRevision = decisionsRevision
    presentationOverride = presentation
    self.store = store
    _selectedDecisionID = selection
    _filters = filters
  }

  var selectedSeverities: Set<DecisionSeverity> {
    Set(
      severitiesCSV
        .split(separator: ",")
        .compactMap { DecisionSeverity(rawValue: String($0)) }
    )
  }

  var searchScope: DecisionsSidebarSearchScope {
    DecisionsSidebarSearchScope(rawValue: searchScopeRaw) ?? .summary
  }

  func setSelectedSeverities(_ newValue: Set<DecisionSeverity>) {
    severitiesCSV = newValue.map(\.rawValue).sorted().joined(separator: ",")
  }

  var presentationTaskKey: DecisionsSidebarPresentationTaskKey {
    DecisionsSidebarPresentationTaskKey(
      decisionsRevision: decisionsRevision,
      decisions: decisions,
      filters: currentFilters
    )
  }

  var currentFilters: DecisionsSidebarViewModel.FilterState {
    .init(
      query: query,
      severities: selectedSeverities,
      scope: searchScope
    )
  }

  var activePresentation: DecisionsSidebarPresentation {
    presentationOverride ?? cachedPresentation
  }

  var activeDecisionsByID: [String: Decision] {
    decisionsByIDOverride ?? cachedDecisionsByID
  }

  func lastAcpMessageAt(
    for decision: Decision
  ) -> Date? {
    store?.acpPermissionLastSignalAt(sessionID: decision.sessionID)
  }

  func acpPayload(
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
    .task(id: presentationTaskKey) {
      await rebuildPresentationIfNeeded()
    }
  }

  @MainActor
  func rebuildPresentationIfNeeded() async {
    guard presentationOverride == nil else {
      return
    }
    presentationGeneration &+= 1
    let generation = presentationGeneration
    let localDecisionsByID =
      decisionsByIDOverride ?? Dictionary(uniqueKeysWithValues: decisions.map { ($0.id, $0) })
    let input = DecisionsSidebarPresentationInput(
      items: decisionItemsOverride ?? decisions.map(DecisionPresentationItem.init),
      filters: currentFilters
    )
    let presentation = await presentationWorker.compute(input: input)
    guard !Task.isCancelled, presentationGeneration == generation else {
      return
    }
    cachedDecisionsByID = localDecisionsByID
    if cachedPresentation != presentation {
      cachedPresentation = presentation
    }
  }

  var header: some View {
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

  var searchRow: some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      TextField(searchScope.label, text: $query)
        .textFieldStyle(.roundedBorder)
        .accessibilityIdentifier(HarnessMonitorAccessibility.decisionsSidebarSearch)
      scopeMenu
      filterToggleButton
    }
  }

  var filterToggleButton: some View {
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

  var scopeMenu: some View {
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

  func publishFilters() {
    filters = DecisionsSidebarViewModel.FilterState(
      query: query,
      severities: selectedSeverities,
      scope: searchScope
    )
  }

  func applyExternalFilters(_ incoming: DecisionsSidebarViewModel.FilterState? = nil) {
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

  var severityChipRow: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        allChip
        ForEach(DecisionSeverity.sidebarOrdering, id: \.self) { severity in
          severityChip(severity)
        }
      }
      .fixedSize(horizontal: true, vertical: false)
      .padding(.leading, HarnessMonitorTheme.spacingXS)
      .padding(.trailing, HarnessMonitorTheme.spacingMD)
      .padding(.vertical, 1)
    }
    .contentMargins(.horizontal, HarnessMonitorTheme.spacingXS, for: .scrollContent)
    .scrollClipDisabled()
  }

  var allChip: some View {
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

  func severityChip(_ severity: DecisionSeverity) -> some View {
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

  @ViewBuilder var content: some View {
    let visibleGroups = activePresentation.groups
    if visibleGroups.isEmpty {
      emptyState
    } else {
      ScrollView {
        LazyVStack(
          alignment: .leading,
          spacing: HarnessMonitorTheme.spacingMD,
          pinnedViews: [.sectionHeaders]
        ) {
          ForEach(visibleGroups) { group in
            sessionSection(group)
          }
        }
        .padding(.vertical, HarnessMonitorTheme.spacingSM)
      }
    }
  }

  var emptyState: some View {
    VStack(spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: "bell.slash")
        .font(.title2)
        .foregroundStyle(.secondary)
      Text("Nothing matches right now")
        .scaledFont(.body)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }

  func sessionSection(
    _ group: DecisionsSidebarPresentationGroup
  ) -> some View {
    Section {
      let decisionsByID = activeDecisionsByID
      ForEach(group.decisionIDs, id: \.self) { decisionID in
        if let decision = decisionsByID[decisionID] {
          DecisionRow(
            decision: decision,
            selection: $selectedDecisionID,
            selectionValue: decision.id,
            fontScale: fontScale,
            acpPayload: acpPayload(for: decision),
            lastMessageAt: lastAcpMessageAt(for: decision)
          )
        }
      }
    } header: {
      sessionHeader(group)
    }
  }

  func sessionHeader(
    _ group: DecisionsSidebarPresentationGroup
  ) -> some View {
    HStack {
      Text(group.sessionID.map(humanizedWorkspaceLabel) ?? "Shared context")
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      Spacer()
      Text("\(group.decisionIDs.count)")
        .scaledFont(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .padding(.vertical, HarnessMonitorTheme.spacingXS)
    .background(.background)
  }
}
