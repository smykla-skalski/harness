import HarnessMonitorKit
import SwiftUI

struct MonitorTimelineSection: View {
  let host: MonitorTimelineHost
  let timeline: [TimelineEntry]
  let timelineWindow: TimelineWindowResponse?
  let decisions: [Decision]
  let isTimelineLoading: Bool
  let store: HarnessMonitorStore

  var sessionID: String { host.id }

  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration
  @Environment(\.harnessTextSizeIndex)
  private var textSizeIndex
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @AppStorage(SessionTimelineFilterDefaults.persistenceModeKey)
  private var filterPersistenceModeRawValue =
    SessionTimelineFilterDefaults.defaultPersistenceMode.rawValue
  @AppStorage(SessionTimelineFilterDefaults.appStateKey)
  private var appStoredFilterStateRawValue = ""
  @SceneStorage(SessionTimelineFilterDefaults.sceneRegistryKey)
  private var sceneStoredFilterRegistryRawValue = ""
  @State private var scrollCommand: SessionTimelineScrollCommand?
  @State private var scrollCommandGeneration = 0
  @State private var pendingNavigationAfterLoad: SessionTimelinePendingNavigation?
  @State private var pendingNavigationGeneration = 0
  @State private var cachedPresentation = SessionTimelineSectionPresentation.empty
  @State private var cachedPresentationInput = SessionTimelinePresentationInput.empty
  @State private var viewport = SessionTimelineViewportModel()
  @State private var filters = SessionTimelineFilterState()

  var body: some View {
    let input = presentationInput
    ViewBodySignposter.measure("MonitorTimelineSection") {
      content(for: cachedPresentation)
    }
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

  @MainActor
  private func rebuildPresentationIfNeeded(
    for input: SessionTimelinePresentationInput,
    force: Bool = false
  ) {
    guard force || cachedPresentationInput != input else {
      return
    }
    let nextPresentation = SessionTimelineSectionPresentation(
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

  private func content(for presentation: SessionTimelineSectionPresentation) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      Text("Timeline")
        .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
        .accessibilityAddTraits(.isHeader)

      if presentation.showsEmptyState {
        SessionCockpitEmptyStateRow(section: .timeline)
      } else {
        timelineSurface(for: presentation)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    // The three modifiers below all use `deferOffViewUpdate { ... }` to hop
    // state writes to the next run-loop turn. Synchronous writes here ran
    // inside SwiftUI's view-update phase and produced an AttributeGraph cycle
    // during ACP timeline bursts (writes to @State scrollCommand +
    // @Observable viewport interleaved with parent body re-eval from store
    // mutations). The helper is the single place that names the rule "no
    // synchronous state mutation in lifecycle handlers on this view"; new
    // handlers must route through it. Per-scroll cost is unchanged because
    // scrollNodeIDs only flips on data update, not per scroll.
    .onAppear {
      deferOffViewUpdate {
        reconcileTimelineAnchor(with: cachedPresentation.scrollNodeIDs)
      }
      requestLatestWindowIfNeeded(presentation)
    }
    .onChange(of: sessionID) { _, _ in
      deferOffViewUpdate {
        viewport.clear()
        scrollCommand = nil
        pendingNavigationAfterLoad = nil
      }
      requestLatestWindow()
    }
    .onChange(of: presentation.scrollNodeIDs) { _, ids in
      guard !ids.isEmpty else { return }
      deferOffViewUpdate {
        reconcileTimelineAnchor(with: ids)
        completePendingNavigationIfNeeded(cachedPresentation)
      }
    }
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
  private func deferOffViewUpdate(_ work: @escaping @MainActor () -> Void) {
    Task { @MainActor in
      work()
    }
  }

  private func timelineSurface(for presentation: SessionTimelineSectionPresentation) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingLG) {
      SessionTimelineFilterControls(
        filters: $filters,
        inventory: presentation.filterSnapshot.inventory,
        summary: presentation.filterSnapshot.summary
      )

      timelineScrollContent(for: presentation)

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

  private func timelineScrollContent(
    for presentation: SessionTimelineSectionPresentation
  ) -> some View {
    Group {
      if presentation.showsFilteredEmptyState {
        SessionTimelineFilteredEmptyState(filters: $filters)
      } else if presentation.rows.isEmpty {
        SessionTimelinePlaceholderScrollView(
          presentation: presentation,
          actionHandler: actionHandler,
          contentIdentity: contentIdentity
        )
      } else {
        GeometryReader { geo in
          SessionTimelineTableView(
            columnWidth: geo.size.width,
            rows: presentation.rows,
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
        }
      }
    }
    .frame(height: presentation.scrollViewportHeight)
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
