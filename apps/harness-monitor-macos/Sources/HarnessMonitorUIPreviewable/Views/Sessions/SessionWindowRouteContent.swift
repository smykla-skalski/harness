import HarnessMonitorKit
import SwiftUI

struct SessionWindowOverview: View {
  let store: HarnessMonitorStore
  let snapshot: HarnessMonitorSessionWindowSnapshot
  let decisions: [Decision]
  let tuiStatusByAgent: [String: AgentTuiStatus]
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: SessionWindowRouteContentMetrics {
    SessionWindowRouteContentMetrics(fontScale: fontScale)
  }

  private var runtimePresentation: HarnessMonitorStore.AgentRuntimePresentationContext? {
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
  }

  var body: some View {
    HarnessMonitorColumnScrollView(
      horizontalPadding: metrics.contentPadding,
      verticalPadding: metrics.contentPadding,
      constrainContentWidth: true,
      readableWidth: false,
      topScrollEdgeEffect: .soft,
      scrollSurfaceIdentifier: HarnessMonitorAccessibility.sessionCockpitScrollView,
      scrollSurfaceLabel: "Session overview"
    ) {
      VStack(alignment: .leading, spacing: metrics.overviewSpacing) {
        Text(snapshot.summary.displayTitle)
          .scaledFont(.system(.title2, design: .rounded, weight: .semibold))
        Grid(
          alignment: .leading,
          horizontalSpacing: metrics.gridHorizontalSpacing,
          verticalSpacing: metrics.gridVerticalSpacing
        ) {
          metric("Status", snapshot.summary.status.title)
          metric("Project", snapshot.summary.projectName)
          metric("Worktree", snapshot.summary.worktreeDisplayName)
          metric("Agents", agentCountText)
          metric("Open tasks", "\(snapshot.summary.metrics.openTaskCount)")
          metric("Source", snapshot.source.rawValue)
        }
        TaskBoardOverviewHost(
          scope: .session(sessionID: snapshot.summary.sessionId),
          store: store,
          snapshot: taskBoardSnapshot,
          taskBoardItems: linkedTaskBoardItems,
          decisions: decisions,
          orchestratorStatus: store.contentUI.dashboard.taskBoardOrchestratorStatus,
          evaluationSummary: store.contentUI.dashboard.taskBoardEvaluationSummary,
          isActionInFlight: store.contentUI.dashboard.isBusy
        )
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func metric(_ title: String, _ value: String) -> some View {
    GridRow {
      Text(title)
        .scaledFont(.body)
        .foregroundStyle(.secondary)
      Text(value)
        .scaledFont(.body)
        .textSelection(.enabled)
    }
  }

  private var agentCount: Int {
    snapshot.detail?.agents.count ?? snapshot.summary.metrics.agentCount
  }

  private var agentCountText: String {
    guard
      runtimePresentation?.availability == .live,
      let detail = snapshot.detail
    else {
      return "\(agentCount)"
    }

    let summary = store.agentRuntimeSummary(
      sessionID: snapshot.summary.sessionId,
      sessionRegistrations: detail.agents,
      tuiStatusByAgent: tuiStatusByAgent,
      runtimePresentation: runtimePresentation
    )
    guard summary.registeredCount > 0 else {
      return "0"
    }
    guard summary.activeCount != summary.registeredCount else {
      return "\(summary.activeCount) active"
    }
    return "\(summary.activeCount) active of \(summary.registeredCount)"
  }

}

struct SessionWindowAgentsList: View {
  let store: HarnessMonitorStore
  let snapshot: HarnessMonitorSessionWindowSnapshot
  let tuiStatusByAgent: [String: AgentTuiStatus]
  let currentModifiers: EventModifiers
  @Bindable var state: SessionWindowStateCache
  @Environment(\.fontScale)
  private var fontScale
  @Environment(\.appSearchModel)
  private var appSearchModel: AppSearchModel?
  @State private var routeSelection = SessionRouteListSelectionState()
  @State private var presentationWorker = SessionRouteListPresentationWorker()
  @State private var cachedPresentation = SessionAgentListPresentation.empty
  @State private var presentationGeneration: UInt64 = 0

  private var metrics: SessionWindowRouteContentMetrics {
    SessionWindowRouteContentMetrics(fontScale: fontScale)
  }

  private var preferredRouteDetailAgentID: String? {
    if case .route(.agents) = state.selection {
      return SessionAgentRouteSelectionPolicy.preferredRouteDetailAgentID(
        rememberedAgentID: state.sectionState.agentID,
        visibleAgentIDs: cachedPresentation.agentIDs
      )
    }
    return state.selection.agentID
  }

  private var selectedAgentIDs: Binding<Set<String>> {
    Binding(
      get: {
        routeSelection.displayedSelection(fallbackPrimaryID: preferredRouteDetailAgentID)
      },
      set: { newSelection in
        applyAgentSelection(newSelection)
      }
    )
  }

  private var searchQuery: String {
    appSearchModel?.query ?? ""
  }

  private var presentationInput: SessionAgentListPresentationInput {
    SessionAgentListPresentationInput(
      agents: snapshot.detail?.agents ?? [],
      query: searchQuery,
      agentOrderIDs: state.sidebarOrdering.agentIDs
    )
  }

  private var runtimePresentation: HarnessMonitorStore.AgentRuntimePresentationContext? {
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
  }

  var body: some View {
    let agents = cachedPresentation.agents
    List(selection: selectedAgentIDs) {
      Section("Agents") {
        if !agents.isEmpty {
          ForEach(agents) { agent in
            let lifecycle = store.agentLifecyclePresentation(
              for: agent,
              sessionID: state.sessionID,
              sessionRegistrations: snapshot.detail?.agents ?? [],
              tuiStatus: tuiStatusByAgent[agent.agentId],
              runtimePresentation: runtimePresentation
            )
            Label {
              VStack(alignment: .leading, spacing: metrics.rowTextSpacing) {
                Text(agent.name)
                  .scaledFont(.body)
                Text(
                  "\(lifecycle.label) - \(agent.role.title) - \(agent.runtime) - \(agent.agentId)"
                )
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
              }
            } icon: {
              Image(systemName: "person.crop.circle")
            }
            .tag(agent.agentId)
            .simultaneousGesture(
              SpatialTapGesture().onEnded { _ in
                collapseToRowFromPlainTap(agent.agentId)
              },
              including: hasActiveMultiSelection ? .gesture : []
            )
            .accessibilityIdentifier(
              HarnessMonitorAccessibility.sessionWindowAgentRow(agent.agentId)
            )
            .contextMenu {
              SessionAgentContextMenuActions(
                store: store,
                state: state,
                leaderID: snapshot.detail?.session.leaderId,
                sessionAgents: snapshot.detail?.agents ?? [],
                resolution: .actionable(
                  SessionSidebarContextMenuScope.resolve(
                    kind: .agent,
                    rowID: agent.agentId,
                    selectedIDs: selectedAgentIDs.wrappedValue,
                    orderedVisibleIDs: cachedPresentation.agentIDs
                  )
                )
              )
            }
          }
        } else if cachedPresentation.hasQuery {
          ContentUnavailableView(
            "No Matching Agents",
            systemImage: SessionWindowRoute.agents.systemImage,
            description: Text("No agents match the current search.")
          )
        } else {
          ContentUnavailableView("No Agents", systemImage: SessionWindowRoute.agents.systemImage)
        }
      }
    }
    .listStyle(.inset)
    .task(id: presentationInput) {
      await rebuildPresentation(input: presentationInput)
    }
    .onChange(of: cachedPresentation.agentIDs) { _, ids in
      let primaryID = routeSelection.prune(
        visibleIDs: Set(ids),
        fallbackPrimaryID: preferredRouteDetailAgentID
      )
      syncPrimaryAgentSelection(primaryID)
    }
    .onChange(of: preferredRouteDetailAgentID) { _, primaryID in
      guard !hasActiveMultiSelection else { return }
      routeSelection.collapse(to: primaryID)
    }
    .onChange(of: state.lastPlainClick) { _, signal in
      collapseSelectionFromApplicationTap(signal)
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

  private var hasActiveMultiSelection: Bool {
    routeSelection.hasActiveMultiSelection(fallbackPrimaryID: preferredRouteDetailAgentID)
  }

  private func applyAgentSelection(_ newSelection: Set<String>) {
    let primaryID = routeSelection.applySelection(
      newSelection,
      fallbackPrimaryID: preferredRouteDetailAgentID
    )
    syncPrimaryAgentSelection(primaryID)
  }

  private func syncPrimaryAgentSelection(_ primaryID: String?) {
    if routeSelection.hasActiveMultiSelection(fallbackPrimaryID: preferredRouteDetailAgentID) {
      state.selectRoute(.agents)
      state.setRouteAgentID(primaryID)
      return
    }

    guard let primaryID else {
      if case .route(.agents) = state.selection {
        state.setRouteAgentID(nil)
      }
      return
    }

    if case .route(.agents) = state.selection {
      guard primaryID != state.sectionState.agentID else { return }
      state.setRouteAgentID(primaryID)
    } else {
      guard primaryID != state.selection.agentID else { return }
      state.selectAgent(primaryID)
    }
  }

  private func collapseToRowFromPlainTap(_ agentID: String) {
    let blocking = currentModifiers.intersection([.command, .shift, .control, .option])
    guard blocking.isEmpty else { return }
    guard hasActiveMultiSelection else { return }
    routeSelection.collapse(to: agentID)
    syncPrimaryAgentSelection(agentID)
  }

  private func collapseSelectionFromApplicationTap(_ signal: SessionPlainClickSignal) {
    let blocking = signal.modifiers.intersection([.command, .shift, .control, .option])
    guard blocking.isEmpty else { return }
    guard hasActiveMultiSelection else { return }
    routeSelection.collapse(to: preferredRouteDetailAgentID)
  }
}
