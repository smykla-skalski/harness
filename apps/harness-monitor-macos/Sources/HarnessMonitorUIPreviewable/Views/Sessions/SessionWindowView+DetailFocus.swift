import HarnessMonitorKit
import SwiftUI

extension SessionWindowView {
  @ViewBuilder var detailFocus: some View {
    detailFocusContent(for: detailRenderedSelection ?? stateCache.selection)
  }

  @ViewBuilder
  private func detailFocusContent(for selection: SessionSelection) -> some View {
    switch selection {
    case .agent(_, let agentID):
      agentDetailContent(for: agentID)
    case .route(.agents):
      routeAgentDetailContent()
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

  @ViewBuilder
  private func routeAgentDetailContent() -> some View {
    if let agentID = SessionAgentRouteSelectionPolicy.preferredRouteDetailAgentID(
      rememberedAgentID: stateCache.sectionState.agentID,
      visibleAgentIDs: visibleSessionAgents.map(\.agentId)
    ) {
      agentDetailContent(for: agentID)
    } else {
      let hasQuery = !stateCache.appSearchModel.query
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .isEmpty
      unavailableDetailSurface(
        hasQuery ? "No Matching Agents" : "No Agents",
        systemImage: SessionWindowRoute.agents.systemImage,
        description: Text(
          hasQuery
            ? "No agents match the current search."
            : "This session does not have any agents."
        )
      )
    }
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

  @ViewBuilder
  private func agentDetailContent(for agentID: String) -> some View {
    if let snapshot,
      let detail = snapshot.detail,
      let agent = detail.agents.first(where: { $0.agentId == agentID })
    {
      let agentTimeline = snapshot.timelineEntriesByAgentID[agentID] ?? []
      let agentTranscript = snapshot.transcriptEntriesByAgentID[agentID] ?? []
      SessionAgentDetailSection(
        store: store,
        sessionID: token.sessionID,
        detail: detail,
        runtimePresentation: {
          switch snapshot.source {
          case .live:
            return HarnessMonitorStore.AgentRuntimePresentationContext(
              availability: .live,
              acpSnapshots: snapshot.acpAgents,
              acpInspectSample: snapshot.acpInspectSample
            )
          case .cache:
            return HarnessMonitorStore.AgentRuntimePresentationContext(availability: .persisted)
          case .catalog:
            return nil
          }
        }(),
        agentTimeline: agentTimeline,
        agentTranscript: agentTranscript,
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
  }
}
