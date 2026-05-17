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
  @State private var presentationWorker = SessionTimelinePresentationWorker()
  @State private var cachedPresentation = SessionTimelineSectionPresentation.empty
  @State private var presentationGeneration: UInt64 = 0
  @State private var loadOlderInFlight = false
  @State private var didInitialFreshFetch = false
  @State private var measuredContainerHeight: CGFloat = 0

  static let fallbackPageSize = 10
  static let estimatedRowHeight: CGFloat = 56

  var pageSize: Int {
    guard measuredContainerHeight > 0 else { return Self.fallbackPageSize }
    let rows = Int((measuredContainerHeight / Self.estimatedRowHeight).rounded(.up))
    return max(Self.fallbackPageSize, rows)
  }

  func updateMeasuredContainerHeight(_ height: CGFloat) {
    guard height >= 0, measuredContainerHeight != height else { return }
    measuredContainerHeight = height
  }

  private var presentationInput: SessionTimelineSectionPresentationInput {
    SessionTimelineSectionPresentationInput(
      sessionID: sessionID,
      timeline: timeline,
      timelineWindow: timelineWindow,
      decisions: decisions.map(SessionTimelineDecisionInput.init(decision:)),
      signals: store.selectedSessionSignals,
      filters: normalizedFilters(filters),
      isTimelineLoading: isTimelineLoading,
      dateTimeConfiguration: dateTimeConfiguration
    )
  }

  private var presentationTaskKey: SessionTimelinePresentationTaskKey {
    SessionTimelinePresentationTaskKey(
      sessionID: sessionID,
      timelineRevision: store.presentedTimelineRevision,
      timelineWindowRevision: store.presentedTimelineWindowRevision,
      timelineFallbackSignature: .init(timeline),
      timelineWindowSignature: .init(timelineWindow),
      decisionsRevision: store.supervisorDecisionRefreshTick,
      decisionsCount: decisions.count,
      signalsRevision: store.selectedSessionSignalsRevision,
      filters: normalizedFilters(filters),
      isTimelineLoading: isTimelineLoading,
      dateTimeConfiguration: dateTimeConfiguration
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

  func markInitialFreshFetchRequested() -> Bool {
    guard !didInitialFreshFetch else { return false }
    didInitialFreshFetch = true
    return true
  }

  private var routeMetrics: SessionWindowRouteContentMetrics {
    SessionWindowRouteContentMetrics(fontScale: fontScale)
  }

  var actionHandler: any DecisionActionHandler {
    store.supervisorDecisionActionHandler()
  }

  var body: some View {
    let presentation = cachedPresentation
    let taskKey = presentationTaskKey
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
    .task(id: taskKey) {
      await rebuildPresentation()
    }
    .task(id: HarnessMonitorUITestEnvironment.perfScenarioRawValue ?? "") {
      applyPerfScenarioFiltersIfNeeded()
    }
    .onAppear { requestLatestWindowIfNeeded(cachedPresentation) }
    .onGeometryChange(for: CGFloat.self, of: \.size.height) { _, height in
      updateMeasuredContainerHeight(height)
    }
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

  @MainActor
  private func rebuildPresentation() async {
    presentationGeneration &+= 1
    let generation = presentationGeneration
    let input = presentationInput
    let presentation = await presentationWorker.compute(input)
    guard !Task.isCancelled, presentationGeneration == generation else {
      return
    }
    if cachedPresentation != presentation {
      cachedPresentation = presentation
    }
    requestLatestWindowIfNeeded(presentation)
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
        filters: $filters,
        onRequestLoadOlder: requestLoadOlderTimelineChunk
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
          filters: $filters,
          onRequestLoadOlder: requestLoadOlderTimelineChunk
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

  func requestLoadOlderTimelineChunk() {
    Task { @MainActor in
      // Escape the scroll-geometry callback before mutating SwiftUI state.
      await Task.yield()

      let oldestCursor =
        timelineWindow?.oldestCursor
        ?? timeline.last.map { TimelineCursor(recordedAt: $0.recordedAt, entryId: $0.entryId) }
      let limit = pageSize
      if let timelineLoading, let oldestCursor {
        if loadOlderInFlight { return }
        loadOlderInFlight = true
        let request = TimelineWindowRequest(
          scope: .summary,
          limit: limit,
          before: oldestCursor
        )
        defer { loadOlderInFlight = false }
        await timelineLoading.loadWindow(request, nil)
        return
      }
      await store.appendSelectedTimelineOlderChunk(
        limit: limit,
        retainedLimit: nil
      )
    }
  }
}
