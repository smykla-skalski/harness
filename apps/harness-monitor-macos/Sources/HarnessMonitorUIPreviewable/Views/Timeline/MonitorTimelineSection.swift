import HarnessMonitorKit
import SwiftUI

struct SessionTimelineView: View {
  let style: SessionTimelineViewStyle
  let host: MonitorTimelineHost
  let timeline: [TimelineEntry]
  let timelineWindow: TimelineWindowResponse?
  let decisions: [Decision]
  let isTimelineLoading: Bool
  let store: HarnessMonitorStore
  let timelineLoading: SessionTimelineLoading?

  var sessionID: String { host.id }

  init(
    style: SessionTimelineViewStyle,
    host: MonitorTimelineHost,
    timeline: [TimelineEntry],
    timelineWindow: TimelineWindowResponse?,
    decisions: [Decision],
    isTimelineLoading: Bool,
    store: HarnessMonitorStore,
    timelineLoading: SessionTimelineLoading? = nil
  ) {
    self.style = style
    self.host = host
    self.timeline = timeline
    self.timelineWindow = timelineWindow
    self.decisions = decisions
    self.isTimelineLoading = isTimelineLoading
    self.store = store
    self.timelineLoading = timelineLoading
  }

  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration
  @Environment(\.fontScale)
  private var fontScale

  @AppStorage(SessionTimelineFilterDefaults.persistenceModeKey)
  var filterPersistenceModeRawValue =
    SessionTimelineFilterDefaults.defaultPersistenceMode.rawValue
  @AppStorage(SessionTimelineFilterDefaults.appStateKey)
  var appStoredFilterStateRawValue =
    SessionTimelineFilterDefaults.defaultAppStateRawValue
  @SceneStorage(SessionTimelineFilterDefaults.sceneRegistryKey)
  var sceneStoredFilterRegistryRawValue = ""

  @State private var filters = SessionTimelineFilterState()
  @State private var presentationCache = SessionTimelineSectionPresentationCache()

  private var presentation: SessionTimelineSectionPresentation {
    presentationCache.presentation(
      SessionTimelineSectionPresentationInput(
        sessionID: sessionID,
        timeline: timeline,
        timelineWindow: timelineWindow,
        decisions: decisions,
        signals: store.selectedSessionSignals,
        filters: normalizedFilters(filters),
        isTimelineLoading: isTimelineLoading,
        dateTimeConfiguration: dateTimeConfiguration
      )
    )
  }

  var filterPersistenceMode: SessionTimelineFilterPersistenceMode {
    SessionTimelineFilterPersistenceMode(rawValue: filterPersistenceModeRawValue)
      ?? SessionTimelineFilterDefaults.defaultPersistenceMode
  }

  var filterState: SessionTimelineFilterState {
    get { filters }
    nonmutating set { filters = newValue }
  }

  private var routeMetrics: SessionWindowRouteContentMetrics {
    SessionWindowRouteContentMetrics(fontScale: fontScale)
  }

  var actionHandler: any DecisionActionHandler {
    store.supervisorDecisionActionHandler()
  }

  var body: some View {
    let presentation = self.presentation
    Group {
      switch style {
      case .cockpitSection:
        cockpitContent(for: presentation)
      case .routePage:
        routePageContent(for: presentation)
      }
    }
    .task(id: filterHydrationInput) {
      hydrateFilters(for: filterHydrationInput)
      applyPerfScenarioFiltersIfNeeded()
    }
    .task(id: HarnessMonitorUITestEnvironment.perfScenarioRawValue ?? "") {
      applyPerfScenarioFiltersIfNeeded()
    }
    .onAppear { requestLatestWindowIfNeeded(presentation) }
    .onChange(of: host.id) { _, _ in requestLatestWindow() }
    .onChange(of: filters) { _, newValue in
      persistFilters(normalizedFilters(newValue))
    }
    .onChange(of: filterPersistenceModeRawValue) { _, _ in
      persistFilters(normalizedFilters(filters))
    }
    .modifier(
      SessionTimelineSearchMirror(
        filterQuery: $filters.query,
        isEnabled: style == .routePage
      )
    )
  }

  @ViewBuilder
  private func cockpitContent(
    for presentation: SessionTimelineSectionPresentation
  ) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      Text("Timeline")
        .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
        .accessibilityAddTraits(.isHeader)

      if presentation.showsEmptyState {
        SessionCockpitEmptyStateRow(section: .timeline)
      } else {
        cockpitTimelineSurface(for: presentation)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func cockpitTimelineSurface(
    for presentation: SessionTimelineSectionPresentation
  ) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingLG) {
      SessionTimelineFilterControls(
        filters: $filters,
        inventory: presentation.filterSnapshot.inventory,
        summary: presentation.filterSnapshot.summary
      )

      SessionTimelineList(
        presentation: presentation,
        actionHandler: actionHandler,
        onSignalTap: handleSignalTap,
        fontScale: fontScale,
        horizontalContentInset: 0,
        filters: $filters
      )
      .frame(minHeight: 260, maxHeight: 470)

      if presentation.navigation.showsNavigation {
        SessionTimelineCountSummary(
          navigation: presentation.navigation,
          filterSummary: presentation.filterSnapshot.summary,
          filterMatchCount: presentation.filterMatchCountForVisibilityStats
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timeline navigation")
        .accessibilityIdentifier(HarnessMonitorAccessibility.sessionTimelineNavigation)
      }
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .background {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusLG, style: .continuous)
        .fill(.primary.opacity(0.035))
        .overlay {
          RoundedRectangle(
            cornerRadius: HarnessMonitorTheme.cornerRadiusLG,
            style: .continuous
          )
          .stroke(HarnessMonitorTheme.controlBorder.opacity(0.55), lineWidth: 1)
        }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func routePageContent(
    for presentation: SessionTimelineSectionPresentation
  ) -> some View {
    VStack(alignment: .leading, spacing: routeMetrics.overviewSpacing) {
      routePageHeader(for: presentation)

      if presentation.showsEmptyState {
        ContentUnavailableView(
          "No Timeline Events",
          systemImage: "clock.arrow.circlepath",
          description: Text("This session has not recorded timeline activity yet.")
        )
        .padding(.horizontal, routeMetrics.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        SessionTimelineList(
          presentation: presentation,
          actionHandler: actionHandler,
          onSignalTap: handleSignalTap,
          fontScale: fontScale,
          horizontalContentInset: routeMetrics.contentPadding,
          filters: $filters
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  @ViewBuilder
  private func routePageHeader(
    for presentation: SessionTimelineSectionPresentation
  ) -> some View {
    VStack(alignment: .leading, spacing: routeMetrics.overviewSpacing) {
      HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingMD) {
        Text("Timeline")
          .scaledFont(.system(.title2, design: .rounded, weight: .semibold))
          .accessibilityAddTraits(.isHeader)

        Spacer(minLength: HarnessMonitorTheme.spacingLG)

        if !presentation.showsEmptyState {
          HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
            if presentation.navigation.showsNavigation {
              SessionTimelineCountSummary(
                navigation: presentation.navigation,
                filterSummary: presentation.filterSnapshot.summary,
                filterMatchCount: presentation.filterMatchCountForVisibilityStats
              )
            }
            SessionTimelineFilterActionButtons(
              filters: $filters,
              inventory: presentation.filterSnapshot.inventory,
              showsClearButton: false
            )
          }
        }
      }
      .padding(.horizontal, routeMetrics.contentPadding)
      .padding(.top, routePageTopPadding)

      if !presentation.showsEmptyState {
        SessionTimelineFilterControls(
          filters: $filters,
          inventory: presentation.filterSnapshot.inventory,
          summary: presentation.filterSnapshot.summary,
          layout: .chipsOnly
        )
        .padding(.horizontal, routeMetrics.contentPadding)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private var routePageTopPadding: CGFloat {
    max(
      HarnessMonitorTheme.spacingSM,
      min(routeMetrics.contentPadding * 0.5, HarnessMonitorTheme.spacingLG)
    )
  }

  private func normalizedFilters(_ state: SessionTimelineFilterState) -> SessionTimelineFilterState
  {
    var copy = state
    copy.searchScope = .all
    return copy
  }

  func handleSignalTap(_ signalID: String) {
    store.presentedSheet = .signalDetail(signalID: signalID)
  }
}

private struct SessionTimelineList: View {
  let presentation: SessionTimelineSectionPresentation
  let actionHandler: any DecisionActionHandler
  let onSignalTap: ((String) -> Void)?
  let fontScale: CGFloat
  let horizontalContentInset: CGFloat
  let filters: Binding<SessionTimelineFilterState>

  @State private var railEndpoints = SessionTimelineRailEndpoints()

  init(
    presentation: SessionTimelineSectionPresentation,
    actionHandler: any DecisionActionHandler,
    onSignalTap: ((String) -> Void)?,
    fontScale: CGFloat,
    horizontalContentInset: CGFloat,
    filters: Binding<SessionTimelineFilterState>
  ) {
    self.presentation = presentation
    self.actionHandler = actionHandler
    self.onSignalTap = onSignalTap
    self.fontScale = fontScale
    self.horizontalContentInset = horizontalContentInset
    self.filters = filters
  }

  var body: some View {
    Group {
      if presentation.showsFilteredEmptyState {
        SessionTimelineFilteredEmptyState(filters: filters)
      } else if presentation.rows.isEmpty && presentation.navigation.isLoading {
        ProgressView()
          .controlSize(.small)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        timelineScroll
      }
    }
  }

  private var timelineScroll: some View {
    let firstID = presentation.rows.first?.id
    let lastID = presentation.rows.last?.id
    return ScrollView(.vertical) {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(presentation.rows) { row in
          SessionTimelineRowView(
            row: row,
            actionHandler: actionHandler,
            onSignalTap: onSignalTap,
            fontScale: fontScale,
            railRole: SessionTimelineRailRole.role(
              for: row.id,
              firstID: firstID,
              lastID: lastID
            )
          )
          .equatable()
          .id(row.id)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .coordinateSpace(.named(SessionTimelineRailCoordinateSpace.name))
      .background(alignment: .topLeading) {
        if !presentation.rows.isEmpty {
          SessionTimelineRailBackground(endpoints: railEndpoints)
        }
      }
      .onPreferenceChange(SessionTimelineRailEndpointsKey.self) { newValue in
        let merged = railEndpoints.merging(newValue)
        if merged != railEndpoints {
          railEndpoints = merged
        }
      }
      .padding(.horizontal, horizontalContentInset)
    }
    .scrollIndicators(.visible)
    .scrollBounceBehavior(.basedOnSize, axes: .vertical)
  }
}

struct SessionTimelineFilteredEmptyState: View {
  @Binding var filters: SessionTimelineFilterState

  var body: some View {
    VStack(spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: "line.3.horizontal.decrease.circle")
        .font(.title2)
        .foregroundStyle(.secondary)
      Text("No timeline items match these filters")
        .scaledFont(.body.weight(.semibold))
      Button("Clear filters") {
        filters.clear()
      }
      .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(HarnessMonitorTheme.spacingLG)
  }
}
