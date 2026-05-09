import HarnessMonitorKit
import SwiftUI

public enum SessionWindowFocusModePolicy {
  public static func usesRouteContent(selection: SessionSelection) -> Bool {
    selection.route != nil
  }
}

extension SessionWindowView {
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
          .backgroundExtensionEffect()
      }
    }
  }

  @ViewBuilder var standardSessionLayout: some View {
    NavigationSplitView(columnVisibility: columnVisibilityBinding) {
      SessionSidebar(
        store: store,
        snapshot: snapshot,
        decisions: matchingDecisions,
        state: stateCache
      )
      .padding(.top, HarnessMonitorTheme.spacingLG)
      .navigationSplitViewColumnWidth(min: 190, ideal: sidebarWidth, max: 360)
    } detail: {
      sessionBannerStack {
        SessionContentDetailSplitView(contentWidth: $contentColumnWidth) {
          contentColumn
            .padding(.top, HarnessMonitorTheme.spacingLG)
        } detail: {
          detailColumn
            .padding(.top, HarnessMonitorTheme.spacingLG)
        }
      }
    }
    .navigationSplitViewStyle(.prominentDetail)
  }

  @ViewBuilder
  private func sessionBannerStack<Content: View>(
    @ViewBuilder content: () -> Content
  ) -> some View {
    SessionBannerStack(
      store: store,
      sessionID: token.sessionID,
      pendingDecisionCount: 0,
      content: content
    )
  }

  @ViewBuilder var sessionSurface: some View {
    if focusMode {
      focusModeSurface
        .padding(.top, HarnessMonitorTheme.spacingLG)
    } else {
      standardSessionLayout
    }
  }

  @ViewBuilder var contentColumn: some View {
    if isLoading && snapshot == nil {
      ProgressView("Loading session")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let snapshot {
      contentColumnBody(snapshot: snapshot, route: contentRenderedRoute ?? route)
    } else {
      ContentUnavailableView(
        "Session Not Available",
        systemImage: "questionmark.folder",
        description: Text(token.sessionID)
      )
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
      MonitorTimelineSection(
        host: .session(snapshot.summary.sessionId),
        timeline: snapshot.timeline,
        timelineWindow: snapshot.timelineWindow,
        decisions: matchingDecisions,
        isTimelineLoading: isLoading,
        store: store
      )
      .padding(24)
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
          .backgroundExtensionEffect()
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
        updateDetailColumnWidth(
          geometry.size.width,
          visibleBinding: $inspectorVisible,
          preferredBinding: $inspectorPreferred,
          announce: false
        )
      }
      .onChange(of: geometry.size.width) { _, newWidth in
        updateDetailColumnWidth(
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
          composerFocusRequestID: stateCache.agentComposerFocusRequestID
        )
      } else {
        ContentUnavailableView(
          "Agent \(agentID)",
          systemImage: "person.crop.circle",
          description: Text("Agent detail is not available.")
        )
      }
    case .decision(_, let decisionID):
      if let decision = allSessionDecisionsCache.first(where: { $0.id == decisionID }) {
        VStack(alignment: .leading, spacing: 12) {
          if !matchingDecisionIDsCache.contains(decisionID) {
            SessionFilteredDecisionNotice(filters: stateCache.decisionFilters)
          }
          SessionDecisionDetailPane(
            decision: decision,
            runtime: stateCache.decisionRuntime
          )
        }
      } else {
        ContentUnavailableView(
          "No Decision Selected",
          systemImage: "exclamationmark.bubble"
        )
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
        ContentUnavailableView(
          "Task Not Available",
          systemImage: "checklist",
          description: Text(taskID)
        )
      }
    case .create(let draft):
      SessionWindowCreateForm(
        store: store,
        state: stateCache,
        draft: draft
      )
    case .route:
      ContentUnavailableView(
        "Select an Item",
        systemImage: "sidebar.right",
        description: Text("Pick an agent, decision, or task in the sidebar.")
      )
    }
  }
}
