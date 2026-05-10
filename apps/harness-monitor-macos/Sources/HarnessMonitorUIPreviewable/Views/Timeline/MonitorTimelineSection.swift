import Combine
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

  var sessionID: String { host.id }

  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration
  @Environment(\.fontScale)
  private var fontScale
  @Environment(\.harnessTextSizeIndex)
  private var textSizeIndex
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @State private var filterPersistenceModeRawValue =
    SessionTimelineFilterDefaults.readPersistenceModeRawValue()
  @State private var appStoredFilterStateRawValue =
    SessionTimelineFilterDefaults.readAppStateRawValue()
  @SceneStorage(SessionTimelineFilterDefaults.sceneRegistryKey)
  private var sceneStoredFilterRegistryRawValue = ""
  @State private var scrollCommand: SessionTimelineScrollCommand?
  @State private var scrollCommandGeneration = 0
  @State private var pendingNavigationAfterLoad: SessionTimelinePendingNavigation?
  @State private var pendingNavigationGeneration = 0
  @State private var pendingEdgeLoadAction: SessionTimelineWindowAction?
  @State private var cachedPresentation = SessionTimelineSectionPresentation.empty
  @State private var cachedPresentationInput = SessionTimelinePresentationInput.empty
  @State private var viewport = SessionTimelineViewportModel()
  @State private var filters = SessionTimelineFilterState()

  var body: some View {
    let input = presentationInput
    let displayPresentation = presentationForBody(input: input)
    content(for: displayPresentation)
      // .task(id:) hops state writes off the view-update phase. Synchronous
      // .onAppear/.onChange writes here interleaved @State (cachedPresentation)
      // and @Observable (viewport) mutations during body eval, surfacing as an
      // AttributeGraph cycle when ACP timeline bursts arrived faster than the
      // run loop could drain (rdar://timeline-burst). Yield once so SwiftUI can
      // cancel superseded same-frame input bursts before they mutate state; that
      // removes the "update multiple times per frame" fault without touching the
      // table's measurement, height cache, or scrolling paths.
      .task(id: input) {
        await Task.yield()
        guard !Task.isCancelled else {
          return
        }
        rebuildPresentationIfNeeded(for: input)
      }
      .task(id: filterHydrationInput) {
        hydrateFilters(for: filterHydrationInput)
      }
      .task(id: edgeLoadRetryInput(for: displayPresentation)) {
        await Task.yield()
        guard !Task.isCancelled else {
          return
        }
        retryPendingEdgeLoadIfNeeded(for: displayPresentation)
      }
      .onReceive(
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
          .receive(on: RunLoop.main)
      ) { _ in
        refreshStoredFilterDefaults()
      }
      .onChange(of: filters) { _, newValue in
        persistFilters(newValue)
      }
      .onChange(of: filterPersistenceModeRawValue) { _, _ in
        persistFilters(filters)
      }
  }

  private var presentationInput: SessionTimelinePresentationInput {
    SessionTimelinePresentationInput(
      sessionID: sessionID,
      timelineCount: timeline.count,
      firstTimelineEntryID: timeline.first?.entryId,
      firstTimelineRecordedAt: timeline.first?.recordedAt,
      lastTimelineEntryID: timeline.last?.entryId,
      lastTimelineRecordedAt: timeline.last?.recordedAt,
      timelineWindowRevision: timelineWindow?.revision,
      timelineWindowStart: timelineWindow?.windowStart,
      timelineWindowEnd: timelineWindow?.windowEnd,
      timelineWindowHasOlder: timelineWindow?.hasOlder ?? false,
      timelineWindowHasNewer: timelineWindow?.hasNewer ?? false,
      decisionCount: decisions.count,
      firstDecisionID: decisions.first?.id,
      lastDecisionID: decisions.last?.id,
      signalCount: store.selectedSessionSignals.count,
      isTimelineLoading: isTimelineLoading,
      filterSignature: filters.signature,
      reduceMotion: reduceMotion,
      textSizeIndex: textSizeIndex,
      dateTimeConfiguration: dateTimeConfiguration
    )
  }

  private var filterHydrationInput: SessionTimelineFilterHydrationInput {
    SessionTimelineFilterHydrationInput(
      sessionID: sessionID,
      appStateRawValue: appStoredFilterStateRawValue,
      sceneRegistryRawValue: sceneStoredFilterRegistryRawValue
    )
  }

  private var filterPersistenceMode: SessionTimelineFilterPersistenceMode {
    SessionTimelineFilterPersistenceMode(rawValue: filterPersistenceModeRawValue)
      ?? SessionTimelineFilterDefaults.defaultPersistenceMode
  }

  private func refreshStoredFilterDefaults(userDefaults: UserDefaults = .standard) {
    let nextPersistenceModeRawValue =
      SessionTimelineFilterDefaults.readPersistenceModeRawValue(userDefaults: userDefaults)
    if filterPersistenceModeRawValue != nextPersistenceModeRawValue {
      filterPersistenceModeRawValue = nextPersistenceModeRawValue
    }
    let nextAppStateRawValue = SessionTimelineFilterDefaults.readAppStateRawValue(
      userDefaults: userDefaults
    )
    if appStoredFilterStateRawValue != nextAppStateRawValue {
      appStoredFilterStateRawValue = nextAppStateRawValue
    }
  }

  private var routeMetrics: SessionWindowRouteContentMetrics {
    SessionWindowRouteContentMetrics(fontScale: fontScale)
  }

  @MainActor
  private func rebuildPresentationIfNeeded(
    for input: SessionTimelinePresentationInput,
    force: Bool = false
  ) {
    guard force || cachedPresentationInput != input else {
      return
    }
    let nextPresentation = makePresentation()
    cachedPresentation = SessionTimelinePresentationRetention.resolved(
      previousPresentation: cachedPresentation,
      previousInput: cachedPresentationInput,
      nextPresentation: nextPresentation,
      nextInput: input
    )
    cachedPresentationInput = input
    viewport.updatePresentationCounts(
      windowStart: cachedPresentation.navigation.windowStart,
      loaded: cachedPresentation.navigation.loadedCount,
      total: cachedPresentation.navigation.totalCount,
      filteredMatchCount: cachedPresentation.filterMatchCountForVisibilityStats
    )
    viewport.recordInitialViewport(
      estimatedVisibleEvents: min(
        cachedPresentation.navigation.loadedCount,
        cachedPresentation.fallbackVisibleRowCount
      )
    )
  }

  private func presentationForBody(
    input: SessionTimelinePresentationInput
  ) -> SessionTimelineSectionPresentation {
    if cachedPresentationInput == .empty || cachedPresentationInput.sessionID != input.sessionID {
      return makePresentation()
    }
    return cachedPresentation
  }

  private func makePresentation() -> SessionTimelineSectionPresentation {
    SessionTimelineSectionPresentation(
      sessionID: sessionID,
      timeline: timeline,
      timelineWindow: timelineWindow,
      decisions: decisions,
      signals: store.selectedSessionSignals,
      filters: filters,
      isTimelineLoading: isTimelineLoading,
      reduceMotion: reduceMotion,
      textSizeIndex: textSizeIndex,
      dateTimeConfiguration: dateTimeConfiguration
    )
  }

  @ViewBuilder
  private func content(for presentation: SessionTimelineSectionPresentation) -> some View {
    switch style {
    case .cockpitSection:
      cockpitSectionContent(for: presentation)
    case .routePage:
      routePageContent(for: presentation)
    }
  }

  private func cockpitSectionContent(
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
    .timelineLifecycle(for: presentation, host: self)
  }

  private func routePageContent(for presentation: SessionTimelineSectionPresentation) -> some View {
    VStack(alignment: .leading, spacing: routeMetrics.overviewSpacing) {
      Text("Timeline")
        .scaledFont(.system(.title2, design: .rounded, weight: .semibold))
        .accessibilityAddTraits(.isHeader)

      if presentation.showsEmptyState {
        ContentUnavailableView(
          "No Timeline Events",
          systemImage: "clock.arrow.circlepath",
          description: Text("This session has not recorded timeline activity yet.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        SessionTimelineFilterControls(
          filters: $filters,
          inventory: presentation.filterSnapshot.inventory,
          summary: presentation.filterSnapshot.summary
        )

        routeTimelineContent(for: presentation)

        if presentation.navigation.showsNavigation {
          SessionTimelineNavigationControls(
            navigation: presentation.navigation,
            presentation: presentation,
            filterSummary: presentation.filterSnapshot.summary,
            scrollCommandTargetID: scrollCommand?.targetID,
            viewport: viewport,
            performAction: { action in
              performNavigationAction(action, presentation: presentation)
            }
          )
        }
      }
    }
    .padding(routeMetrics.contentPadding)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .timelineLifecycle(for: presentation, host: self)
  }

  /// Run a state-mutating closure on the next run-loop turn instead of inside
  /// SwiftUI's current view-update phase. Required for any write that touches
  /// `@State` or `@Observable` storage read by this view's body or its
  /// observable children — see the cycle context comment on `content(for:)`.
  ///
  /// Cost is one unstructured `Task` allocation per call. Callers must only
  /// invoke this from change-event handlers (`.onAppear`, `.onChange`), never
  /// from per-scroll publishes; the latter would allocate per frame and
  /// regress the body-update budget.
  func deferOffViewUpdate(_ work: @escaping @MainActor () -> Void) {
    Task { @MainActor in
      work()
    }
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

      timelineRows(for: presentation)
        .frame(height: presentation.scrollViewportHeight)

      if presentation.navigation.showsNavigation {
        SessionTimelineNavigationControls(
          navigation: presentation.navigation,
          presentation: presentation,
          filterSummary: presentation.filterSnapshot.summary,
          scrollCommandTargetID: scrollCommand?.targetID,
          viewport: viewport,
          performAction: { action in
            performNavigationAction(action, presentation: presentation)
          }
        )
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

  private func routeTimelineContent(
    for presentation: SessionTimelineSectionPresentation
  ) -> some View {
    timelineRows(for: presentation)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  @ViewBuilder
  private func timelineRows(
    for presentation: SessionTimelineSectionPresentation
  ) -> some View {
    if presentation.showsFilteredEmptyState {
      SessionTimelineFilteredEmptyState(filters: $filters)
    } else if presentation.rows.isEmpty {
      SessionTimelinePlaceholderScrollView(
        presentation: presentation,
        actionHandler: actionHandler,
        contentIdentity: contentIdentity
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } else {
      SessionTimelineTableView(
        columnWidth: 0,
        rows: presentation.rows,
        contentIdentity: contentIdentity,
        scrollCommand: scrollCommand,
        actionHandler: actionHandler,
        onSignalTap: { [store] signalID in
          store.presentedSheet = .signalDetail(signalID: signalID)
        },
        viewport: viewport,
        scrollBoundaryChanged: { oldValue, newValue in
          handleScrollBoundaryChange(
            from: oldValue,
            to: newValue,
            presentation: presentation
          )
        }
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  var timelineNavigationAnchorID: String? {
    viewport.visibleAnchorID ?? scrollCommand?.targetID
  }

  var currentTimelineScrollCommand: SessionTimelineScrollCommand? {
    get { scrollCommand }
    nonmutating set { scrollCommand = newValue }
  }

  var currentTimelineScrollCommandGeneration: Int {
    get { scrollCommandGeneration }
    nonmutating set { scrollCommandGeneration = newValue }
  }

  var currentPendingNavigation: SessionTimelinePendingNavigation? {
    get { pendingNavigationAfterLoad }
    nonmutating set { pendingNavigationAfterLoad = newValue }
  }

  var currentPendingNavigationGeneration: Int {
    get { pendingNavigationGeneration }
    nonmutating set { pendingNavigationGeneration = newValue }
  }

  var currentPendingEdgeLoadAction: SessionTimelineWindowAction? {
    get { pendingEdgeLoadAction }
    nonmutating set { pendingEdgeLoadAction = newValue }
  }

  var timelineViewport: SessionTimelineViewportModel {
    viewport
  }

  var currentFilterPersistenceMode: SessionTimelineFilterPersistenceMode {
    filterPersistenceMode
  }

  var currentFilters: SessionTimelineFilterState {
    get { filters }
    nonmutating set { filters = newValue }
  }

  var currentAppStoredFilterStateRawValue: String {
    get { appStoredFilterStateRawValue }
    nonmutating set { appStoredFilterStateRawValue = newValue }
  }

  var currentSceneStoredFilterRegistryRawValue: String {
    get { sceneStoredFilterRegistryRawValue }
    nonmutating set { sceneStoredFilterRegistryRawValue = newValue }
  }
}
