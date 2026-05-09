import HarnessMonitorKit
import SwiftUI

public enum SessionWindowFocusModePolicy {
  public static func usesRouteContent(selection: SessionSelection) -> Bool {
    selection.route != nil
  }
}

extension SessionWindowView {
  func pendingUserPrompt(for agentID: String) -> AgentPendingUserPrompt? {
    guard
      let prompt = snapshot?.detail?.agentActivity
        .first(where: { $0.agentId == agentID })?
        .pendingUserPrompt,
      prompt.primaryQuestion != nil
    else {
      return nil
    }
    return prompt
  }

  var sessionSidebarSearchAvailable: Bool {
    !focusMode && columnVisibilityBinding.wrappedValue != .detailOnly
  }

  var decisionsCacheTrigger: SessionDecisionFilterKey {
    SessionDecisionFilterKey(
      sessionID: token.sessionID,
      decisions: store.supervisorOpenDecisions.filter { $0.sessionID == token.sessionID },
      filters: stateCache.decisionFilters
    )
  }

  func recomputeDecisionsCache() async {
    let all = store.supervisorOpenDecisions.filter { $0.sessionID == token.sessionID }
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
    let matchingIDs = Set(matching.map(\.id))
    if matching.map(\.id) != matchingDecisionsCache.map(\.id) {
      matchingDecisionsCache = matching
    }
    if matchingIDs != matchingDecisionIDsCache {
      matchingDecisionIDsCache = matchingIDs
    }
  }

  @ViewBuilder var focusModeSurface: some View {
    sessionBannerStack {
      if SessionWindowFocusModePolicy.usesRouteContent(selection: stateCache.selection) {
        contentColumn
      } else {
        detailFocus
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  @ViewBuilder var standardSessionLayout: some View {
    NavigationSplitView(columnVisibility: columnVisibilityBinding) {
      SessionSidebar(
        store: store,
        snapshot: snapshot,
        sessionCodexRuns: sessionCodexRuns,
        decisions: matchingDecisions,
        canPresentSearch: sessionSidebarSearchAvailable,
        state: stateCache
      )
      .navigationSplitViewColumnWidth(min: 190, ideal: sidebarWidth, max: 360)
    } detail: {
      sessionBannerStack {
        standardSessionDetailSurface
      }
    }
    .navigationSplitViewStyle(.prominentDetail)
  }

  @ViewBuilder
  private var standardSessionDetailSurface: some View {
    switch renderedRoute.layoutStyle {
    case .sidebarDetail:
      routeDetailColumn
    case .sidebarContentDetail:
      SessionContentDetailSplitView(contentWidth: $contentColumnWidth) {
        contentColumn
      } detail: {
        detailColumn
      }
    }
  }

  @ViewBuilder
  private var routeDetailColumn: some View {
    contentColumn
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        store: store
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
            width: $inspectorWidth,
            minWidth: 220,
            maxWidth: 420
          )
          SessionWindowInspector(
            decision: inspectorDecision,
            isFilteredOut: selectedDecisionHiddenByFilters,
            decisionFilters: stateCache.decisionFilters,
            decisionRuntime: stateCache.decisionRuntime,
            visible: $inspectorVisible,
            preferredVisible: $inspectorPreferred
          )
          .frame(width: max(220, min(inspectorWidth, 420)))
        }
      }
      .onAppear {
        deferDetailColumnWidthUpdate(
          geometry.size.width,
          visibleBinding: $inspectorVisible,
          preferredBinding: $inspectorPreferred,
          announce: false
        )
      }
      .onChange(of: geometry.size.width) { _, newWidth in
        deferDetailColumnWidthUpdate(
          newWidth,
          visibleBinding: $inspectorVisible,
          preferredBinding: $inspectorPreferred
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
      if let agent = snapshot?.detail?.agents.first(where: { $0.agentId == agentID }) {
        SessionAgentDetailSection(
          store: store,
          sessionID: token.sessionID,
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
      if let decision = allSessionDecisionsCache.first(where: { $0.id == decisionID }) {
        SessionDecisionDetailPane(
          decision: decision,
          runtime: stateCache.decisionRuntime,
          filters: stateCache.decisionFilters,
          showsFilteredNotice: !matchingDecisionIDsCache.contains(decisionID)
        )
      } else {
        SessionDetailEmptySurface {
          ContentUnavailableView(
            "No Decision Selected",
            systemImage: "exclamationmark.bubble"
          )
        }
      }
    case .task(_, let taskID):
      if let task = snapshot?.detail?.tasks.first(where: { $0.taskId == taskID }) {
        SessionTaskDetailPane(
          task: task,
          openActions: {
            store.presentedSheet = .taskActions(
              sessionID: token.sessionID,
              taskID: task.taskId
            )
          }
        )
      } else {
        SessionDetailEmptySurface {
          ContentUnavailableView(
            "Task Not Available",
            systemImage: "checklist",
            description: Text(taskID)
          )
        }
      }
    case .codexRun(_, let runID):
      if let run = sessionCodexRuns.first(where: { $0.runId == runID }) {
        SessionCodexRunDetailSection(store: store, run: run)
      } else {
        SessionDetailEmptySurface {
          ContentUnavailableView(
            "Codex Run Not Available",
            systemImage: "wand.and.stars",
            description: Text(runID)
          )
        }
      }
    case .create(let draft):
      SessionWindowCreateForm(
        store: store,
        state: stateCache,
        draft: draft,
        embedsRuntimeConfiguration: focusMode
      )
    case .route:
      SessionDetailEmptySurface {
        ContentUnavailableView(
          "Select an Item",
          systemImage: "sidebar.right",
          description: Text("Pick an agent, decision, or task in the sidebar.")
        )
      }
    }
  }

  var sessionCodexRuns: [CodexRunSnapshot] {
    store.selectedCodexRuns.filter { $0.sessionId == token.sessionID }
  }
}
