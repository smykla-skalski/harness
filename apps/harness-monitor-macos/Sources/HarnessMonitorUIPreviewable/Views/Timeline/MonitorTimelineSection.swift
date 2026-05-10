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
  @Environment(\.harnessTextSizeIndex)
  private var textSizeIndex
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  // @AppStorage is keyed: SwiftUI only invalidates when the specific
  // UserDefaults key changes. Switching from @State + a global
  // UserDefaults.didChangeNotification observer eliminates the broadcast
  // that fired on every keystroke when other parts of the app (e.g.
  // agent-composer drafts) wrote unrelated UserDefaults keys.
  @AppStorage(SessionTimelineFilterDefaults.persistenceModeKey)
  var filterPersistenceModeRawValue =
    SessionTimelineFilterDefaults.defaultPersistenceMode.rawValue
  @AppStorage(SessionTimelineFilterDefaults.appStateKey)
  var appStoredFilterStateRawValue =
    SessionTimelineFilterDefaults.defaultAppStateRawValue
  @SceneStorage(SessionTimelineFilterDefaults.sceneRegistryKey)
  var sceneStoredFilterRegistryRawValue = ""
  @State var scrollCommand: SessionTimelineScrollCommand?
  @State var scrollCommandGeneration = 0
  @State var pendingNavigationAfterLoad: SessionTimelinePendingNavigation?
  @State var pendingNavigationGeneration = 0
  @State var pendingEdgeLoad: SessionTimelinePendingEdgeLoad?
  @State private var cachedPresentation = SessionTimelineSectionPresentation.empty
  @State private var cachedPresentationInput = SessionTimelinePresentationInput.empty
  @State var viewport = SessionTimelineViewportModel()
  @State var filters = SessionTimelineFilterState()

  var body: some View {
    let input = presentationInput
    let displayPresentation = presentationForBody(input: input)
    content(for: displayPresentation)
      // Hop presentation writes out of the view-update phase so timeline bursts
      // do not interleave @State and @Observable mutations during body eval.
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
      .onChange(of: filters) { _, newValue in
        persistFilters(normalizedFilters(newValue))
      }
      .onChange(of: filterPersistenceModeRawValue) { _, _ in
        persistFilters(normalizedFilters(filters))
      }
      .modifier(SessionTimelineSearchMirror(filterQuery: $filters.query))
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
      filterSignature: normalizedFilters(filters).signature,
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

  var filterPersistenceMode: SessionTimelineFilterPersistenceMode {
    SessionTimelineFilterPersistenceMode(rawValue: filterPersistenceModeRawValue)
      ?? SessionTimelineFilterDefaults.defaultPersistenceMode
  }

  private var routeMetrics: SessionWindowRouteContentMetrics {
    SessionWindowRouteContentMetrics(fontScale: fontScale)
  }

  private var routePageTopPadding: CGFloat {
    max(
      HarnessMonitorTheme.spacingSM,
      min(routeMetrics.contentPadding * 0.5, HarnessMonitorTheme.spacingLG)
    )
  }

  private var routeHeaderHorizontalPadding: CGFloat {
    routeMetrics.contentPadding
  }

  private var routeTimelineHorizontalContentInset: CGFloat {
    routeMetrics.contentPadding
  }

  private func normalizedFilters(_ state: SessionTimelineFilterState) -> SessionTimelineFilterState {
    var copy = state
    copy.searchScope = .all
    return copy
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
      filters: normalizedFilters(filters),
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
      HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingMD) {
        Text("Timeline")
          .scaledFont(.system(.title2, design: .rounded, weight: .semibold))
          .accessibilityAddTraits(.isHeader)

        Spacer(minLength: HarnessMonitorTheme.spacingLG)

        if !presentation.showsEmptyState {
          HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
            if presentation.navigation.showsNavigation {
              SessionTimelineNavigationVisibilityStatus(
                filterSummary: presentation.filterSnapshot.summary,
                viewport: viewport,
                accessibilityIdentifier:
                  HarnessMonitorAccessibility.sessionTimelineNavigationStatus
              )
            }
            SessionTimelineFilterActionButtons(
              filters: $filters,
              inventory: presentation.filterSnapshot.inventory,
              showsClearButton: false
            )
            if presentation.navigation.showsNavigation {
              SessionTimelineNavigationButtonRow(
                presentation: presentation,
                scrollCommandTargetID: scrollCommand?.targetID,
                viewport: viewport,
                performAction: { action in
                  performNavigationAction(action, presentation: presentation)
                }
              )
            }
          }
        }
      }
      .padding(.horizontal, routeHeaderHorizontalPadding)
      .padding(.top, routePageTopPadding)

      if presentation.showsEmptyState {
        ContentUnavailableView(
          "No Timeline Events",
          systemImage: "clock.arrow.circlepath",
          description: Text("This session has not recorded timeline activity yet.")
        )
        .padding(.horizontal, routeHeaderHorizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        SessionTimelineFilterControls(
          filters: $filters,
          inventory: presentation.filterSnapshot.inventory,
          summary: presentation.filterSnapshot.summary,
          layout: .chipsOnly
        )
        .padding(.horizontal, routeHeaderHorizontalPadding)

        routeTimelineContent(for: presentation)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .timelineLifecycle(for: presentation, host: self)
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
    timelineRows(
      for: presentation,
      horizontalContentInset: routeTimelineHorizontalContentInset
    )
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  @ViewBuilder
  private func timelineRows(
    for presentation: SessionTimelineSectionPresentation,
    horizontalContentInset: CGFloat = 0
  ) -> some View {
    if presentation.showsFilteredEmptyState {
      SessionTimelineFilteredEmptyState(filters: $filters)
    } else if presentation.rows.isEmpty {
      SessionTimelinePlaceholderScrollView(
        presentation: presentation,
        actionHandler: actionHandler,
        contentIdentity: contentIdentity,
        horizontalContentInset: horizontalContentInset
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } else {
      SessionTimelineTableView(
        columnWidth: 0,
        rows: presentation.rows,
        virtualization: presentation.tableVirtualization,
        contentIdentity: contentIdentity,
        horizontalContentInset: horizontalContentInset,
        scrollCommand: scrollCommand,
        actionHandler: actionHandler,
        onSignalTap: { [store] signalID in
          store.presentedSheet = .signalDetail(signalID: signalID)
        },
        viewport: viewport,
        viewportChanged: { stats in
          handleViewportStatsChange(stats, presentation: presentation)
        },
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

}
