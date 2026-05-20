import HarnessMonitorKit
import SwiftUI

extension SessionWindowView {
  @ViewBuilder var detailFocus: some View {
    detailFocusContent(for: detailRenderedSelection ?? stateCache.selection)
  }

  @ViewBuilder
  private func detailFocusContent(for selection: SessionSelection) -> some View {
    if HarnessMonitorPerfIsolation.usesStaticDetail {
      SessionPerfStaticDetailSurface(route: route(for: selection), selection: selection)
    } else {
      switch selection {
      case .agent(_, let agentID):
        agentDetailContent(for: agentID)
      case .route(.agents):
        SessionRouteAgentDetailFocus(
          agents: snapshot?.detail?.agents ?? [],
          state: stateCache,
          detail: { agentID in
            agentDetailContent(for: agentID)
          },
          empty: { hasQuery in
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
        )
      case .decision(_, let decisionID):
        SessionDecisionDetailPane(
          decision: decisionsByID(sessionDecisionDetail, fallbackID: decisionID),
          store: store,
          auditEvents: stateCache.decisionRuntime.auditEvents,
          auditEventPayloadPresentations: stateCache.decisionRuntime.auditEventPayloadPresentations,
          observer: sessionDecisionObserver,
          decisionScope: sessionDecisionScope,
          selectedTab: decisionDetailTabBinding,
          filters: stateCache.decisionFilters,
          showsFilteredNotice: sessionDecisionDetailHiddenByFilters
        )
      case .task(_, let taskID):
        taskDetailContent(for: taskID)
      case .codexRun(_, let runID):
        codexRunDetailContent(for: runID)
      case .openRouterRun(_, let runID):
        openRouterRunDetailContent(for: runID)
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
          auditEventPayloadPresentations: stateCache.decisionRuntime.auditEventPayloadPresentations,
          observer: sessionDecisionObserver,
          decisionScope: sessionDecisionScope,
          selectedTab: decisionDetailTabBinding,
          filters: stateCache.decisionFilters,
          showsFilteredNotice: sessionDecisionDetailHiddenByFilters
        )
      case .route(.tasks):
        SessionRouteTaskDetailFocus(
          tasks: snapshot?.detail?.tasks ?? [],
          state: stateCache,
          detail: { taskID in
            taskDetailContent(for: taskID)
          },
          empty: { hasQuery in
            unavailableDetailSurface(
              hasQuery ? "No Matching Tasks" : "No Tasks",
              systemImage: SessionWindowRoute.tasks.systemImage,
              description: Text(
                hasQuery
                  ? "No tasks match the current search."
                  : "This session does not have any tasks."
              )
            )
          }
        )
      case .route:
        unavailableDetailSurface(
          "Select an Item",
          systemImage: "sidebar.right",
          description: Text("Pick an agent, decision, or task in the sidebar.")
        )
      }
    }
  }

  @ViewBuilder
  private func taskDetailContent(for taskID: String) -> some View {
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
  }

  @ViewBuilder
  private func codexRunDetailContent(for runID: String) -> some View {
    if let run = sessionCodexRuns.first(where: { $0.runId == runID }) {
      SessionCodexRunDetailSection(store: store, run: run)
    } else {
      unavailableDetailSurface(
        "Codex Run Not Available",
        systemImage: "wand.and.stars",
        description: Text(runID)
      )
    }
  }

  @ViewBuilder
  private func openRouterRunDetailContent(for runID: String) -> some View {
    if let run = sessionOpenRouterRuns.first(where: { $0.runId == runID }) {
      SessionOpenRouterRunDetailSection(store: store, run: run)
    } else {
      unavailableDetailSurface(
        "OpenRouter Run Not Available",
        systemImage: "network",
        description: Text(runID)
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

private struct SessionRouteAgentDetailFocus<Detail: View, Empty: View>: View {
  let agents: [AgentRegistration]
  @Bindable var state: SessionWindowStateCache
  let detail: (String) -> Detail
  let empty: (Bool) -> Empty
  @Environment(\.appSearchModel)
  private var appSearchModel: AppSearchModel?
  @State private var presentationWorker = SessionRouteListPresentationWorker()
  @State private var cachedPresentation = SessionAgentListPresentation.empty
  @State private var presentationGeneration: UInt64 = 0

  init(
    agents: [AgentRegistration],
    state: SessionWindowStateCache,
    @ViewBuilder detail: @escaping (String) -> Detail,
    @ViewBuilder empty: @escaping (Bool) -> Empty
  ) {
    self.agents = agents
    self.state = state
    self.detail = detail
    self.empty = empty
  }

  private var query: String {
    appSearchModel?.query ?? ""
  }

  private var hasQuery: Bool {
    !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var presentationInput: SessionAgentListPresentationInput {
    SessionAgentListPresentationInput(
      agents: agents,
      query: query,
      agentOrderIDs: state.sidebarOrdering.agentIDs
    )
  }

  var body: some View {
    Group {
      if let agentID = SessionAgentRouteSelectionPolicy.preferredRouteDetailAgentID(
        rememberedAgentID: state.sectionState.agentID,
        visibleAgentIDs: cachedPresentation.agentIDs
      ) {
        detail(agentID)
      } else {
        empty(cachedPresentation.hasQuery || hasQuery)
      }
    }
    .task(id: presentationInput) {
      await rebuildPresentation(input: presentationInput)
    }
  }

  @MainActor
  private func rebuildPresentation(input: SessionAgentListPresentationInput) async {
    presentationGeneration &+= 1
    let generation = presentationGeneration
    let presentation = await presentationWorker.computeAgents(input: input)
    guard !Task.isCancelled, presentationGeneration == generation else {
      return
    }
    if cachedPresentation != presentation {
      cachedPresentation = presentation
    }
  }
}

private struct SessionRouteTaskDetailFocus<Detail: View, Empty: View>: View {
  let tasks: [WorkItem]
  @Bindable var state: SessionWindowStateCache
  let detail: (String) -> Detail
  let empty: (Bool) -> Empty
  @Environment(\.appSearchModel)
  private var appSearchModel: AppSearchModel?
  @State private var presentationWorker = SessionRouteListPresentationWorker()
  @State private var cachedPresentation = SessionTaskListPresentation.empty
  @State private var presentationGeneration: UInt64 = 0

  init(
    tasks: [WorkItem],
    state: SessionWindowStateCache,
    @ViewBuilder detail: @escaping (String) -> Detail,
    @ViewBuilder empty: @escaping (Bool) -> Empty
  ) {
    self.tasks = tasks
    self.state = state
    self.detail = detail
    self.empty = empty
  }

  private var trimmedQuery: String {
    (appSearchModel?.query ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
  }

  private var hasQuery: Bool {
    !trimmedQuery.isEmpty
  }

  private var presentationInput: SessionTaskListPresentationInput {
    SessionTaskListPresentationInput(tasks: tasks, query: trimmedQuery)
  }

  var body: some View {
    Group {
      if let taskID = SessionTaskRouteSelectionPolicy.preferredRouteDetailTaskID(
        rememberedTaskID: state.sectionState.taskID,
        visibleTaskIDs: cachedPresentation.taskIDs
      ) {
        detail(taskID)
      } else {
        empty(cachedPresentation.hasQuery || hasQuery)
      }
    }
    .task(id: presentationInput) {
      await rebuildPresentation(input: presentationInput)
    }
  }

  @MainActor
  private func rebuildPresentation(input: SessionTaskListPresentationInput) async {
    presentationGeneration &+= 1
    let generation = presentationGeneration
    let presentation = await presentationWorker.computeTasks(input: input)
    guard !Task.isCancelled, presentationGeneration == generation else {
      return
    }
    if cachedPresentation != presentation {
      cachedPresentation = presentation
    }
  }
}
