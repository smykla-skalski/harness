import HarnessMonitorKit
import SwiftUI

extension SessionWindowView {
  func recomputeDecisionsCache() async {
    let all = store.supervisorOpenDecisions.filter { $0.sessionID == token.sessionID }
    let decisionsByID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    let allIDs = Set(all.map(\.id))
    if all.map(\.id) != allSessionDecisionsCache.map(\.id) {
      allSessionDecisionsCache = all
    }
    if allIDs != allSessionDecisionIDsCache {
      allSessionDecisionIDsCache = allIDs
    }
    stateCache.decisionRuntime.updateFilteredDecisions(
      input: SessionDecisionFilterInput(
        sessionID: token.sessionID,
        decisions: all,
        filters: stateCache.decisionFilters
      )
    )
    await stateCache.decisionRuntime.waitForDecisionFilterIdle()
    guard !Task.isCancelled else { return }
    let matching = stateCache.decisionRuntime.filteredDecisions(from: all)
    let matchingIDsInOrder = matching.map(\.id)
    let matchingIDs = Set(matching.map(\.id))
    if matching.map(\.id) != matchingDecisionsCache.map(\.id) {
      matchingDecisionsCache = matching
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
    stateCache.decisionRuntime.reloadAuditEvents(
      from: store.modelContext,
      sessionID: token.sessionID,
      decisions: all
    )
    if let autoSelectedDecisionID = SessionDecisionAutoSelectionPolicy.preferredDecisionID(
      selection: stateCache.selection,
      sessionID: token.sessionID,
      allDecisionIDs: allIDs,
      visibleDecisionIDs: matchingIDsInOrder
    ) {
      stateCache.autoSelectDecision(autoSelectedDecisionID)
      announceDecisionSelectionChange(
        to: autoSelectedDecisionID,
        decisionsByID: decisionsByID,
        reason: .advancedToVisible
      )
    } else if case .route(.decisions) = stateCache.selection,
      let routeDecisionID,
      previousRouteDecisionID != routeDecisionID
    {
      announceDecisionSelectionChange(
        to: routeDecisionID,
        decisionsByID: decisionsByID,
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
      prefix = "Showing first \(severity)."
    case .advancedToVisible:
      prefix = "Previous decision closed. Showing next \(severity)."
    }
    AccessibilityNotification.Announcement("\(prefix) \(decision.summary)").post()
  }

  @ViewBuilder var focusModeSurface: some View {
    sessionBannerStack {
      if SessionWindowFocusModePolicy.usesRouteContent(selection: stateCache.selection) {
        contentColumn
          .backgroundExtensionEffect()
      } else {
        detailFocus
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .backgroundExtensionEffect()
      }
    }
    .modifier(
      SessionWindowPlainTapRecorder(
        stateCache: stateCache,
        isEnabled: stateCache.sidebarSelection.hasActiveMultiSelection
      )
    )
  }

  @ViewBuilder var standardSessionLayout: some View {
    NavigationSplitView(columnVisibility: columnVisibilityBinding) {
      SessionSidebar(
        store: store,
        snapshot: snapshot,
        sessionCodexRuns: sessionCodexRuns,
        decisions: matchingDecisions,
        statusModel: sessionStatusSummaryModel,
        state: stateCache
      )
      .navigationSplitViewColumnWidth(min: 190, ideal: sidebarWidth, max: 360)
    } detail: {
      sessionBannerStack {
        standardSessionDetailSurface
      }
    }
    .navigationSplitViewStyle(.prominentDetail)
    .modifier(
      SessionWindowPlainTapRecorder(
        stateCache: stateCache,
        isEnabled: stateCache.sidebarSelection.hasActiveMultiSelection
      )
    )
  }

  @ViewBuilder private var standardSessionDetailSurface: some View {
    switch renderedRoute.layoutStyle {
    case .sidebarDetail:
      routeDetailColumn
    case .sidebarContentDetail:
      SessionContentDetailSplitView(contentWidth: contentColumnWidthBinding) {
        contentColumn
          .backgroundExtensionEffect()
      } detail: {
        detailColumn
          .backgroundExtensionEffect()
      }
    }
  }

  @ViewBuilder private var routeDetailColumn: some View {
    contentColumn
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .backgroundExtensionEffect()
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
      await Task.yield()
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
      ProgressView("Loading session")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if case .create(let draft) = stateCache.selection, draft.kind == .agent {
      SessionWindowCreateAgentRuntimePane(
        store: store,
        state: stateCache,
        draft: draft
      )
    } else if let snapshot {
      contentColumnBody(snapshot: snapshot, route: renderedRoute)
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
    switch route {
    case .overview: SessionWindowOverview(snapshot: snapshot)
    case .agents: SessionWindowAgentsList(detail: snapshot.detail, state: stateCache)
    case .tasks: SessionWindowTasksList(detail: snapshot.detail, state: stateCache)
    case .decisions:
      SessionWindowDecisionsList(decisions: matchingDecisions, state: stateCache)
    case .timeline:
      SessionTimelineView(
        style: .routePage,
        host: .session(snapshot.summary.sessionId),
        timeline: snapshot.timeline,
        timelineWindow: snapshot.timelineWindow,
        decisions: matchingDecisions,
        isTimelineLoading: isLoading,
        store: store,
        timelineLoading: sessionTimelineLoading
      )
    case .terminal: SessionWindowRunsList(detail: snapshot.detail, state: stateCache)
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

  @ViewBuilder var detailFocus: some View {
    detailFocusContent(for: detailRenderedSelection ?? stateCache.selection)
  }

  @ViewBuilder
  private func detailFocusContent(for selection: SessionSelection) -> some View {
    switch selection {
    case .agent(_, let agentID):
      if let snapshot,
        let detail = snapshot.detail,
        let agent = detail.agents.first(where: { $0.agentId == agentID })
      {
        let agentTimeline = snapshot.timelineEntriesByAgentID[agentID] ?? []
        SessionAgentDetailSection(
          store: store,
          sessionID: token.sessionID,
          detail: detail,
          agentTimeline: agentTimeline,
          agent: agent,
          tui: agentTui(for: agent),
          pendingPrompt: pendingUserPrompt(for: agent.agentId),
          composerFocusRequestID: stateCache.agentComposerFocusRequestID
        )
      } else {
        SessionDetailEmptySurface {
          ContentUnavailableView(
            "Agent \(agentID)",
            systemImage: "person.crop.circle",
            description: Text("Agent detail is not available.")
          )
        }
      }
    case .decision(_, let decisionID):
      SessionDecisionDetailPane(
        decision: decisionsByID(sessionDecisionDetail, fallbackID: decisionID),
        store: store,
        auditEvents: stateCache.decisionRuntime.auditEvents,
        observer: sessionDecisionObserver,
        decisionScope: sessionDecisionScope,
        selectedTab: decisionDetailTabBinding,
        filters: stateCache.decisionFilters,
        showsFilteredNotice: sessionDecisionDetailHiddenByFilters
      )
    case .task(_, let taskID):
      if let task = snapshot?.detail?.tasks.first(where: { $0.taskId == taskID }) {
        SessionTaskDetailPane(
          task: task,
          openActions: { presentTaskActions(for: task.taskId) }
        )
      } else {
        unavailableDetailSurface(
          "Task Not Available",
          systemImage: "checklist",
          description: Text(taskID)
        )
      }
    case .codexRun(_, let runID):
      if let run = sessionCodexRuns.first(where: { $0.runId == runID }) {
        SessionCodexRunDetailSection(store: store, run: run)
      } else {
        unavailableDetailSurface(
          "Codex Run Not Available",
          systemImage: "wand.and.stars",
          description: Text(runID)
        )
      }
    case .create(let draft):
      SessionWindowCreateForm(
        store: store,
        state: stateCache,
        draft: draft,
        embedsRuntimeConfiguration: focusMode
      )
    case .route(.decisions):
      SessionDecisionDetailPane(
        decision: sessionDecisionDetail,
        store: store,
        auditEvents: stateCache.decisionRuntime.auditEvents,
        observer: sessionDecisionObserver,
        decisionScope: sessionDecisionScope,
        selectedTab: decisionDetailTabBinding,
        filters: stateCache.decisionFilters,
        showsFilteredNotice: sessionDecisionDetailHiddenByFilters
      )
    case .route:
      unavailableDetailSurface(
        "Select an Item",
        systemImage: "sidebar.right",
        description: Text("Pick an agent, decision, or task in the sidebar.")
      )
    }
  }

  var sessionCodexRuns: [CodexRunSnapshot] {
    store.selectedCodexRuns.filter { $0.sessionId == token.sessionID }
  }

  private func presentTaskActions(for taskID: String) {
    store.presentedSheet = .taskActions(sessionID: token.sessionID, taskID: taskID)
  }

  @ViewBuilder
  private func unavailableDetailSurface(
    _ title: String,
    systemImage: String,
    description: Text
  ) -> some View {
    SessionDetailEmptySurface {
      ContentUnavailableView(title, systemImage: systemImage, description: description)
    }
  }

  private func decisionsByID(_ decision: Decision?, fallbackID: String) -> Decision? {
    decision ?? allSessionDecisionsCache.first { $0.id == fallbackID }
  }
}
