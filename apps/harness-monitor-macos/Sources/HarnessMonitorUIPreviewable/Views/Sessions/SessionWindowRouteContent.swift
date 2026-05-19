// swiftlint:disable file_length
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
        SessionOverviewInfoStrip(facts: overviewFacts, metrics: metrics)
        TaskBoardOverviewHost(
          scope: .session(sessionID: snapshot.summary.sessionId),
          store: store,
          snapshot: taskBoardSnapshot,
          taskBoardItems: taskBoardSourceItems,
          decisions: decisions,
          orchestratorStatus: store.contentUI.dashboard.taskBoardOrchestratorStatus,
          evaluationSummary: store.contentUI.dashboard.taskBoardEvaluationSummary,
          isActionInFlight: store.contentUI.dashboard.isBusy
        )
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var overviewFacts: [SessionOverviewFact] {
    [
      SessionOverviewFact(title: "Status", value: snapshot.summary.status.title),
      SessionOverviewFact(title: "Project", value: snapshot.summary.projectName),
      SessionOverviewFact(title: "Worktree", value: snapshot.summary.worktreeDisplayName),
      SessionOverviewFact(
        title: "Agents",
        value: agentCountText,
        usesMonospacedDigits: true
      ),
      SessionOverviewFact(
        title: "Open Tasks",
        value: "\(snapshot.summary.metrics.openTaskCount)",
        usesMonospacedDigits: true
      ),
      SessionOverviewFact(title: "Source", value: snapshot.source.rawValue),
    ]
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

private struct SessionOverviewFact: Identifiable {
  let title: String
  let value: String
  let usesMonospacedDigits: Bool
  var id: String { title }

  init(
    title: String,
    value: String,
    usesMonospacedDigits: Bool = false
  ) {
    self.title = title
    self.value = value
    self.usesMonospacedDigits = usesMonospacedDigits
  }
}

private struct SessionOverviewInfoStrip: View {
  let facts: [SessionOverviewFact]
  let metrics: SessionWindowRouteContentMetrics

  var body: some View {
    ViewThatFits(in: .horizontal) {
      cardsRow(expandsToFill: true)
      ScrollView(.horizontal, showsIndicators: true) {
        cardsRow(expandsToFill: false)
          .padding(.vertical, 1)
      }
      .scrollClipDisabled()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func cardsRow(expandsToFill: Bool) -> some View {
    HStack(alignment: .top, spacing: metrics.gridVerticalSpacing) {
      ForEach(facts) { fact in
        SessionOverviewFactCard(fact: fact, metrics: metrics)
          .frame(
            minWidth: metrics.overviewCardMinWidth,
            maxWidth: expandsToFill ? .infinity : nil,
            alignment: .leading
          )
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct SessionOverviewFactCard: View {
  let fact: SessionOverviewFact
  let metrics: SessionWindowRouteContentMetrics
  @Environment(\.fontScale)
  private var fontScale

  private var titleFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.bold), by: fontScale)
  }

  private var valueFont: Font {
    HarnessMonitorTextSize.scaledFont(
      .system(.title3, design: .rounded, weight: .semibold),
      by: fontScale
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: metrics.overviewCardTextSpacing) {
      Text(fact.title.uppercased())
        .font(titleFont)
        .tracking(HarnessMonitorTheme.uppercaseTracking)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      valueView
        .font(valueFont)
        .foregroundStyle(HarnessMonitorTheme.ink)
        .textSelection(.enabled)
        .multilineTextAlignment(.leading)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(
      maxWidth: .infinity,
      minHeight: metrics.overviewCardMinHeight,
      alignment: .leading
    )
    .padding(HarnessMonitorTheme.cardPadding)
    .background {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .fill(HarnessMonitorTheme.ink.opacity(0.04))
    }
    .overlay {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .strokeBorder(HarnessMonitorTheme.controlBorder.opacity(0.32), lineWidth: 1)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(fact.title)
    .accessibilityValue(fact.value)
  }

  @ViewBuilder private var valueView: some View {
    if fact.usesMonospacedDigits {
      Text(verbatim: fact.value)
        .monospacedDigit()
    } else {
      Text(verbatim: fact.value)
    }
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
