import HarnessMonitorKit
import SwiftUI

extension SessionWindowView {
  @MainActor
  func refreshDecisionsCache() async {
    let sessionDecisionIDs = store.supervisorOpenDecisionIDsBySession[token.sessionID] ?? []
    let sessionDecisionItems =
      store.supervisorPresentationItemsBySession[token.sessionID] ?? []
    let all = store.supervisorOpenDecisionsBySession[token.sessionID] ?? []
    let allIDs = Set(sessionDecisionIDs)
    if sessionDecisionIDs != allSessionDecisionIDsInOrderCache {
      allSessionDecisionsCache = all
    }
    if sessionDecisionItems != allSessionDecisionPresentationItemsCache {
      allSessionDecisionPresentationItemsCache = sessionDecisionItems
    }
    let searchProjections =
      store.supervisorSearchProjectionsBySession[token.sessionID] ?? []
    if searchProjections != allSessionDecisionSearchProjectionsCache {
      allSessionDecisionSearchProjectionsCache = searchProjections
    }
    if allIDs != allSessionDecisionIDsCache {
      allSessionDecisionIDsCache = allIDs
    }
    if sessionDecisionIDs != allSessionDecisionIDsInOrderCache {
      allSessionDecisionIDsInOrderCache = sessionDecisionIDs
    }
    await stateCache.decisionRuntime.reloadAuditEvents(
      from: store.supervisorAuditRepository,
      sessionID: token.sessionID,
      decisionItems: sessionDecisionItems
    )
    await refilterDecisionsCache(
      decisions: all,
      decisionItems: sessionDecisionItems,
      allDecisionIDs: allIDs
    )
  }

  @MainActor
  func refilterDecisionsCache() async {
    let cachedItems =
      store.supervisorPresentationItemsBySession[token.sessionID]
      ?? allSessionDecisionPresentationItemsCache
    await refilterDecisionsCache(
      decisions: allSessionDecisionsCache,
      decisionItems: cachedItems.isEmpty && !allSessionDecisionsCache.isEmpty ? nil : cachedItems,
      allDecisionIDs: allSessionDecisionIDsCache
    )
  }

  @MainActor
  private func refilterDecisionsCache(
    decisions all: [Decision],
    decisionItems: [DecisionPresentationSnapshot]? = nil,
    allDecisionIDs allIDs: Set<String>
  ) async {
    let items =
      decisionItems
      ?? all.map(DecisionPresentationSnapshot.init)
    stateCache.decisionRuntime.updateFilteredDecisions(
      input: SessionDecisionFilterInput(
        sessionID: token.sessionID,
        items: items,
        filters: stateCache.decisionFilters
      )
    )
    await stateCache.decisionRuntime.waitForDecisionFilterIdle()
    guard !Task.isCancelled else { return }
    let matchingIDsInOrder = stateCache.decisionRuntime.filteredDecisionIDs
    let matching = matchingIDsInOrder.compactMap { store.supervisorOpenDecisionsByID[$0] }
    let matchingItems = stateCache.decisionRuntime.filteredDecisionItems
    let matchingIDs = stateCache.decisionRuntime.filteredDecisionIDSet
    if matchingIDsInOrder != matchingDecisionIDsInOrderCache {
      matchingDecisionsCache = matching
    }
    if matchingItems != matchingDecisionPresentationItemsCache {
      matchingDecisionPresentationItemsCache = matchingItems
    }
    if matchingIDsInOrder != matchingDecisionIDsInOrderCache {
      matchingDecisionIDsInOrderCache = matchingIDsInOrder
    }
    if matchingIDs != matchingDecisionIDsCache {
      matchingDecisionIDsCache = matchingIDs
    }
    let previousRouteDecisionID = stateCache.sectionState.decisionID
    let routeDecisionID = SessionDecisionAutoSelectionPolicy.preferredRouteDetailDecisionID(
      rememberedDecisionID: previousRouteDecisionID,
      allDecisionIDs: allIDs,
      visibleDecisionIDs: matchingIDsInOrder
    )
    if previousRouteDecisionID != routeDecisionID {
      stateCache.setRouteDecisionID(routeDecisionID)
    }
    if didLoadSnapshot,
      let autoSelectedDecisionID = SessionDecisionAutoSelectionPolicy.preferredDecisionID(
        selection: stateCache.selection,
        sessionID: token.sessionID,
        allDecisionIDs: allIDs,
        visibleDecisionIDs: matchingIDsInOrder
      )
    {
      stateCache.autoSelectDecision(autoSelectedDecisionID)
      announceDecisionSelectionChange(
        to: autoSelectedDecisionID,
        decisionsByID: store.supervisorOpenDecisionsByID,
        reason: .advancedToVisible
      )
    } else if case .route(.decisions) = stateCache.selection,
      let routeDecisionID,
      previousRouteDecisionID != routeDecisionID
    {
      announceDecisionSelectionChange(
        to: routeDecisionID,
        decisionsByID: store.supervisorOpenDecisionsByID,
        reason: previousRouteDecisionID == nil ? .openedRoute : .advancedToVisible
      )
    }
  }

  private enum SessionDecisionSelectionAnnouncementReason {
    case openedRoute
    case advancedToVisible
  }

  private func announceDecisionSelectionChange(
    to decisionID: String,
    decisionsByID: [String: Decision],
    reason: SessionDecisionSelectionAnnouncementReason
  ) {
    guard let decision = decisionsByID[decisionID] else {
      return
    }
    let severity =
      DecisionSeverity(rawValue: decision.severityRaw)?
      .chipLabel
      .lowercased()
      ?? "decision"
    let prefix: String
    switch reason {
    case .openedRoute:
      prefix = "Showing first \(severity)"
    case .advancedToVisible:
      prefix = "Previous decision closed. Showing next \(severity)"
    }
    AccessibilityNotification.Announcement("\(prefix) \(decision.summary)").post()
  }

  @ViewBuilder var focusModeSurface: some View {
    sessionBannerStack {
      Group {
        if SessionWindowFocusModePolicy.usesRouteContent(selection: stateCache.selection) {
          contentColumn
        } else {
          detailFocus
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
    .modifier(
      SessionWindowPlainTapRecorder(
        stateCache: stateCache,
        isEnabled: stateCache.sidebarSelection.hasActiveMultiSelection
          || renderedRoute == .agents
          || renderedRoute == .tasks
          || renderedRoute == .decisions
      )
    )
    .toolbar { sessionToolbar }
  }

  @ViewBuilder var standardSessionLayout: some View {
    SessionWindowStandardLayout(
      stateCache: stateCache,
      contentDetailBaseWidth: contentColumnWidth,
      perfContentDividerWidth: perfContentDividerWidthBinding,
      sessionID: token.sessionID,
      snapshot: snapshot,
      decisionIDs: allSessionDecisionIDsInOrderCache,
      sidebarWidth: sidebarWidth,
      recordsPlainTaps: recordsPlainTaps
    ) {
      SessionSidebar(
        store: store,
        snapshot: snapshot,
        sessionCodexRuns: sessionCodexRuns,
        sessionOpenRouterRuns: sessionOpenRouterRuns,
        decisions: allSessionDecisions,
        decisionIDs: allSessionDecisionIDsInOrderCache,
        statusModel: sessionStatusSummaryModel,
        currentModifiers: presentedModifiers,
        state: stateCache
      )
    } detail: {
      sessionBannerStack {
        standardSessionDetailSurface
      }
      .toolbar { sessionToolbar }
    }
  }

  private var recordsPlainTaps: Bool {
    stateCache.sidebarSelection.hasActiveMultiSelection
      || renderedRoute == .agents
      || renderedRoute == .tasks
      || renderedRoute == .decisions
  }

  @ViewBuilder private var standardSessionDetailSurface: some View {
    Group {
      switch renderedRoute.layoutStyle {
      case .sidebarDetail:
        contentColumn
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      case .sidebarContentDetail:
        SessionContentDetailSplitView(
          contentWidth: contentColumnWidthBinding,
          perfOverrideContentWidth: perfContentDividerWidthBinding,
          commitContentWidth: commitContentColumnWidth
        ) {
          contentColumn
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } detail: {
          detailColumn
        }
      }
    }
  }

  @ViewBuilder
  private func sessionBannerStack<Content: View>(
    @ViewBuilder content: () -> Content
  ) -> some View {
    SessionBannerStack(
      store: store,
      sessionID: token.sessionID,
      isFocusMode: focusMode,
      isLoading: isLoading,
      hasSnapshot: snapshot != nil,
      pendingDecisionCount: allSessionDecisionsCache.count,
      selectDecisions: { stateCache.selectRoute(.decisions) },
      content: content
    )
  }

  private func deferDetailColumnWidthUpdate(
    _ width: CGFloat,
    visibleBinding: Binding<Bool>,
    preferredBinding: Binding<Bool>,
    announce: Bool = true
  ) {
    // Delay layout-driven writes until after SwiftUI finishes the current
    // geometry pass; synchronous updates here trigger the startup CGFloat fault.
    Task { @MainActor in
      await SessionGeometryWritebackDeferral.nextMainActorTurn()
      updateDetailColumnWidth(
        width,
        visibleBinding: visibleBinding,
        preferredBinding: preferredBinding,
        announce: announce
      )
    }
  }

  @ViewBuilder var sessionSurface: some View {
    if focusMode {
      focusModeSurface
    } else {
      standardSessionLayout
    }
  }

  @ViewBuilder var contentColumn: some View {
    if isLoading && snapshot == nil {
      Label("Loading session", systemImage: "hourglass")
        .scaledFont(.body.weight(.medium))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if case .create(let draft) = stateCache.selection, draft.kind == .agent {
      SessionWindowCreateAgentRuntimePane(
        store: store,
        state: stateCache,
        draft: draft
      )
    } else if let snapshot {
      contentColumnBody(snapshot: snapshot, route: renderedRoute)
        .environment(\.appSearchModel, stateCache.appSearchModel)
    } else {
      SessionDetailEmptySurface {
        ContentUnavailableView(
          "Session Not Available",
          systemImage: "questionmark.folder",
          description: Text(token.sessionID)
        )
      }
    }
  }

  @ViewBuilder
  private func contentColumnBody(
    snapshot: HarnessMonitorSessionWindowSnapshot,
    route: SessionWindowRoute
  ) -> some View {
    if HarnessMonitorPerfIsolation.usesStaticDetail {
      SessionPerfStaticDetailSurface(route: route, selection: stateCache.selection)
    } else {
      switch route {
      case .overview:
        SessionWindowOverview(
          store: store,
          snapshot: snapshot,
          decisions: matchingDecisions,
          tuiStatusByAgent: store.contentUI.sessionDetail.tuiStatusByAgent
        )
      case .policyCanvas:
        SessionPolicyCanvasRedirectView()
      case .agents:
        SessionWindowAgentsList(
          store: store,
          snapshot: snapshot,
          tuiStatusByAgent: store.contentUI.sessionDetail.tuiStatusByAgent,
          currentModifiers: presentedModifiers,
          state: stateCache
        )
      case .tasks:
        SessionWindowTasksList(
          store: store,
          detail: snapshot.detail,
          decisions: matchingDecisions,
          currentModifiers: presentedModifiers,
          state: stateCache
        )
      case .decisions:
        SessionWindowDecisionsList(
          decisions: matchingDecisions,
          decisionIDs: matchingDecisionIDsInOrderCache,
          currentModifiers: presentedModifiers,
          state: stateCache
        )
      case .timeline:
        SessionTimelineView(
          style: .routePage,
          host: .session(snapshot.summary.sessionId),
          timeline: snapshot.timeline,
          timelineWindow: snapshot.timelineWindow,
          decisions: matchingDecisions,
          decisionSnapshots: matchingDecisionPresentationItemsCache,
          isTimelineLoading: isLoading,
          store: store,
          timelineLoading: sessionTimelineLoading,
          focusedEntryID: stateCache.sectionState.timelineEntryID
        )
      }
    }
  }

  @ViewBuilder var detailColumn: some View {
    GeometryReader { geometry in
      let inspectorAllowed =
        inspectorContextDecision != nil
        && !focusMode
        && stateCache.decisionRuntime.allowsInspector(width: geometry.size.width)
      HStack(spacing: 0) {
        detailFocus
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        if inspectorVisible, inspectorAllowed, let inspectorDecision = inspectorContextDecision {
          SessionInspectorDivider(
            width: inspectorWidthBinding,
            commitWidth: commitInspectorWidth,
            minWidth: 220,
            maxWidth: 420
          )
          SessionWindowInspector(
            decision: inspectorDecision,
            isFilteredOut: selectedDecisionHiddenByFilters,
            decisionFilters: stateCache.decisionFilters,
            decisionRuntime: stateCache.decisionRuntime,
            visible: inspectorVisibleBinding,
            preferredVisible: inspectorPreferredBinding
          )
          .frame(width: max(220, min(inspectorWidth, 420)))
        }
      }
      .onAppear {
        deferDetailColumnWidthUpdate(
          geometry.size.width,
          visibleBinding: inspectorVisibleBinding,
          preferredBinding: inspectorPreferredBinding,
          announce: false
        )
      }
      .onChange(of: geometry.size.width) { _, newWidth in
        deferDetailColumnWidthUpdate(
          newWidth,
          visibleBinding: inspectorVisibleBinding,
          preferredBinding: inspectorPreferredBinding
        )
      }
    }
  }

  var sessionCodexRuns: [CodexRunSnapshot] {
    store.codexRuns(forSessionID: token.sessionID)
  }

  var sessionOpenRouterRuns: [OpenRouterRunSnapshot] {
    store.openRouterRuns(forSessionID: token.sessionID)
  }
}
