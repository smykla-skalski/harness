import HarnessMonitorKit
import SwiftUI

extension SessionWindowView {
  @ViewBuilder var contentColumn: some View {
    if isLoading && snapshot == nil {
      ProgressView("Loading session")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let snapshot {
      switch route {
      case .overview: SessionWindowOverview(snapshot: snapshot)
      case .agents: SessionWindowAgentsList(detail: snapshot.detail)
      case .tasks: SessionWindowTasksList(detail: snapshot.detail)
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
      case .terminal: SessionWindowRunsList(detail: snapshot.detail)
      }
    } else {
      ContentUnavailableView(
        "Session Not Available",
        systemImage: "questionmark.folder",
        description: Text(token.sessionID)
      )
    }
  }

  @ViewBuilder var detailColumn: some View {
    GeometryReader { geometry in
      let inspectorAllowed = inspectorContextDecision != nil
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
    switch stateCache.selection {
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
    case .decision:
      if let selectedDecision {
        VStack(alignment: .leading, spacing: 12) {
          if selectedDecisionHiddenByFilters {
            SessionFilteredDecisionNotice(filters: stateCache.decisionFilters)
          }
          SessionDecisionDetailPane(
            decision: selectedDecision,
            runtime: stateCache.decisionRuntime
          )
        }
      } else {
        ContentUnavailableView(
          selectedDecisionVisibility == .missing
            ? "Decision Not Available"
            : "No Decision Selected",
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
