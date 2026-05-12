import HarnessMonitorKit
import SwiftUI

struct SessionWindowOverview: View {
  let store: HarnessMonitorStore
  let snapshot: HarnessMonitorSessionWindowSnapshot
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

  private var metrics: SessionWindowRouteContentMetrics {
    SessionWindowRouteContentMetrics(fontScale: fontScale)
  }

  private var preferredRouteDetailAgentID: String? {
    if case .route(.agents) = state.selection {
      return SessionAgentRouteSelectionPolicy.preferredRouteDetailAgentID(
        rememberedAgentID: state.sectionState.agentID,
        visibleAgentIDs: orderedFilteredAgents.map(\.agentId)
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

  private var hasQuery: Bool {
    !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var filteredAgents: [AgentRegistration] {
    SessionWindowAgentFilter.filteredAgents(snapshot.detail?.agents ?? [], query: searchQuery)
  }

  private var orderedFilteredAgents: [AgentRegistration] {
    state.sidebarOrdering.orderedAgents(filteredAgents)
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
    let agents = orderedFilteredAgents
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
                    orderedVisibleIDs: agents.map(\.agentId)
                  )
                )
              )
            }
          }
        } else if hasQuery {
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
    .onChange(of: filteredAgents.map(\.agentId)) { _, ids in
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

struct SessionWindowTasksList: View {
  let store: HarnessMonitorStore
  let detail: SessionDetail?
  let decisions: [Decision]
  let currentModifiers: EventModifiers
  @Bindable var state: SessionWindowStateCache
  @Environment(\.fontScale)
  private var fontScale
  @Environment(\.appSearchModel)
  private var appSearchModel: AppSearchModel?
  @State private var routeSelection = SessionRouteListSelectionState()

  private var metrics: SessionWindowRouteContentMetrics {
    SessionWindowRouteContentMetrics(fontScale: fontScale)
  }

  private var preferredRouteDetailTaskID: String? {
    if case .route(.tasks) = state.selection {
      return SessionTaskRouteSelectionPolicy.preferredRouteDetailTaskID(
        rememberedTaskID: state.sectionState.taskID,
        visibleTaskIDs: filteredTasks.map(\.taskId)
      )
    }
    return state.selection.taskID
  }

  private var selectedTaskIDs: Binding<Set<String>> {
    Binding(
      get: {
        routeSelection.displayedSelection(fallbackPrimaryID: preferredRouteDetailTaskID)
      },
      set: { newSelection in
        applyTaskSelection(newSelection)
      }
    )
  }

  private var trimmedQuery: String {
    (appSearchModel?.query ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
  }

  private var filteredTasks: [WorkItem] {
    let tasks = detail?.tasks ?? []
    let needle = trimmedQuery
    guard !needle.isEmpty else { return tasks }
    return tasks.filter { task in
      if task.title.lowercased().contains(needle) { return true }
      if let context = task.context?.lowercased(), context.contains(needle) {
        return true
      }
      if let fix = task.suggestedFix?.lowercased(), fix.contains(needle) {
        return true
      }
      if task.taskId.lowercased().contains(needle) { return true }
      return false
    }
  }

  var body: some View {
    let tasks = filteredTasks
    List(selection: selectedTaskIDs) {
      Section("Tasks") {
        if !tasks.isEmpty {
          ForEach(tasks) { task in
            Label {
              VStack(alignment: .leading, spacing: metrics.rowTextSpacing) {
                Text(task.title)
                  .scaledFont(.body)
                Text("\(task.status.title) - \(task.severity.title)")
                  .scaledFont(.caption)
                  .foregroundStyle(.secondary)
              }
            } icon: {
              Image(systemName: "checklist")
            }
            .tag(task.taskId)
            .simultaneousGesture(
              SpatialTapGesture().onEnded { _ in
                collapseToRowFromPlainTap(task.taskId)
              },
              including: hasActiveMultiSelection ? .gesture : []
            )
            .accessibilityIdentifier(HarnessMonitorAccessibility.sessionWindowTaskRow(task.taskId))
            .contextMenu {
              SessionTaskContextMenuActions(
                store: store,
                state: state,
                tasks: detail?.tasks ?? [],
                decisions: decisions,
                resolution: .actionable(
                  SessionSidebarContextMenuScope.resolve(
                    kind: .task,
                    rowID: task.taskId,
                    selectedIDs: selectedTaskIDs.wrappedValue,
                    orderedVisibleIDs: tasks.map(\.taskId)
                  )
                )
              )
            }
          }
        } else if !trimmedQuery.isEmpty {
          ContentUnavailableView(
            "No Matching Tasks",
            systemImage: "checklist",
            description: Text("No tasks match the current search.")
          )
        } else {
          ContentUnavailableView("No Tasks", systemImage: "checklist")
        }
      }
    }
    .listStyle(.inset)
    .onChange(of: filteredTasks.map(\.taskId)) { _, ids in
      let primaryID = routeSelection.prune(
        visibleIDs: Set(ids),
        fallbackPrimaryID: preferredRouteDetailTaskID
      )
      syncPrimaryTaskSelection(primaryID)
    }
    .onChange(of: preferredRouteDetailTaskID) { _, primaryID in
      guard !hasActiveMultiSelection else { return }
      routeSelection.collapse(to: primaryID)
    }
    .onChange(of: state.lastPlainClick) { _, signal in
      collapseSelectionFromApplicationTap(signal)
    }
  }

  private var hasActiveMultiSelection: Bool {
    routeSelection.hasActiveMultiSelection(fallbackPrimaryID: preferredRouteDetailTaskID)
  }

  private func applyTaskSelection(_ newSelection: Set<String>) {
    let primaryID = routeSelection.applySelection(
      newSelection,
      fallbackPrimaryID: preferredRouteDetailTaskID
    )
    syncPrimaryTaskSelection(primaryID)
  }

  private func syncPrimaryTaskSelection(_ primaryID: String?) {
    if routeSelection.hasActiveMultiSelection(fallbackPrimaryID: preferredRouteDetailTaskID) {
      state.selectRoute(.tasks)
      state.setRouteTaskID(primaryID)
      return
    }

    guard let primaryID else {
      if case .route(.tasks) = state.selection {
        state.setRouteTaskID(nil)
      }
      return
    }

    if case .route(.tasks) = state.selection {
      guard primaryID != state.sectionState.taskID else { return }
      state.setRouteTaskID(primaryID)
    } else {
      guard primaryID != state.selection.taskID else { return }
      state.selectTask(primaryID)
    }
  }

  private func collapseToRowFromPlainTap(_ taskID: String) {
    let blocking = currentModifiers.intersection([.command, .shift, .control, .option])
    guard blocking.isEmpty else { return }
    guard hasActiveMultiSelection else { return }
    routeSelection.collapse(to: taskID)
    syncPrimaryTaskSelection(taskID)
  }

  private func collapseSelectionFromApplicationTap(_ signal: SessionPlainClickSignal) {
    let blocking = signal.modifiers.intersection([.command, .shift, .control, .option])
    guard blocking.isEmpty else { return }
    guard hasActiveMultiSelection else { return }
    routeSelection.collapse(to: preferredRouteDetailTaskID)
  }
}

struct SessionWindowDecisionsList: View {
  let decisions: [Decision]
  let currentModifiers: EventModifiers
  @Bindable var state: SessionWindowStateCache
  @Environment(\.fontScale)
  private var fontScale
  @State private var routeSelection = SessionRouteListSelectionState()

  private var metrics: SessionWindowRouteContentMetrics {
    SessionWindowRouteContentMetrics(fontScale: fontScale)
  }

  private var preferredRouteDetailDecisionID: String? {
    if case .route(.decisions) = state.selection {
      return SessionDecisionAutoSelectionPolicy.preferredRouteDetailDecisionID(
        rememberedDecisionID: state.sectionState.decisionID,
        allDecisionIDs: Set(decisions.map(\.id)),
        visibleDecisionIDs: decisions.map(\.id)
      )
    }
    return state.selection.decisionID
  }

  private var selectedDecisionIDs: Binding<Set<String>> {
    Binding(
      get: {
        routeSelection.displayedSelection(fallbackPrimaryID: preferredRouteDetailDecisionID)
      },
      set: { newSelection in
        applyDecisionSelection(newSelection)
      }
    )
  }

  var body: some View {
    List(selection: selectedDecisionIDs) {
      if decisions.isEmpty {
        ContentUnavailableView(
          emptyStateTitle,
          systemImage: "exclamationmark.bubble",
          description: Text(emptyStateDescription)
        )
      } else {
        ForEach(decisions) { decision in
          VStack(alignment: .leading, spacing: metrics.rowTextSpacing) {
            Text(decision.summary)
              .scaledFont(.body)
              .lineLimit(1)
            Text("\(decisionSeverityLabel(for: decision)) - \(decision.ruleID)")
              .scaledFont(.caption)
              .foregroundStyle(.secondary)
          }
          .tag(decision.id)
          .contentShape(Rectangle())
          .simultaneousGesture(
            SpatialTapGesture().onEnded { _ in
              collapseToRowFromPlainTap(decision.id)
            },
            including: hasActiveMultiSelection ? .gesture : []
          )
          .accessibilityElement(children: .combine)
          .accessibilityAddTraits(.isButton)
          .accessibilityLabel(decisionAccessibilityLabel(for: decision))
          .accessibilityIdentifier(HarnessMonitorAccessibility.decisionRow(decision.id))
          .contextMenu {
            SessionDecisionContextMenuActions(
              resolution: .actionable(
                SessionSidebarContextMenuScope.resolve(
                  kind: .decision,
                  rowID: decision.id,
                  selectedIDs: selectedDecisionIDs.wrappedValue,
                  orderedVisibleIDs: decisions.map(\.id)
                )
              )
            )
          }
          .harnessMCPRow(
            HarnessMonitorAccessibility.decisionRow(decision.id),
            label: decisionAccessibilityLabel(for: decision),
            value:
              selectedDecisionIDs.wrappedValue.contains(decision.id) ? "selected" : "not selected",
            pressAction: {
              applyDecisionSelection([decision.id])
            }
          )
        }
      }
    }
    .listStyle(.inset)
    .onChange(of: decisions.map(\.id)) { _, ids in
      let primaryID = routeSelection.prune(
        visibleIDs: Set(ids),
        fallbackPrimaryID: preferredRouteDetailDecisionID
      )
      syncPrimaryDecisionSelection(primaryID)
    }
    .onChange(of: preferredRouteDetailDecisionID) { _, primaryID in
      guard !hasActiveMultiSelection else { return }
      routeSelection.collapse(to: primaryID)
    }
    .onChange(of: state.lastPlainClick) { _, signal in
      collapseSelectionFromApplicationTap(signal)
    }
  }

  private func decisionAccessibilityLabel(for decision: Decision) -> String {
    "\(decisionSeverityLabel(for: decision)). \(decision.summary). \(decision.ruleID)"
  }

  private var emptyStateTitle: String {
    hasActiveFilters ? "No Matching Decisions" : "No Pending Decisions"
  }

  private var emptyStateDescription: String {
    if hasActiveFilters {
      return
        "Clear or broaden the current filters to bring this session's decisions back into view."
    }
    return "This session has no open decisions right now."
  }

  private var hasActiveFilters: Bool {
    let query = state.decisionFilters.query.trimmingCharacters(in: .whitespacesAndNewlines)
    return !query.isEmpty || !state.decisionFilters.severities.isEmpty
  }

  private func decisionSeverityLabel(for decision: Decision) -> String {
    DecisionSeverity(rawValue: decision.severityRaw)?.chipLabel ?? "Decision"
  }

  private var hasActiveMultiSelection: Bool {
    routeSelection.hasActiveMultiSelection(fallbackPrimaryID: preferredRouteDetailDecisionID)
  }

  private func applyDecisionSelection(_ newSelection: Set<String>) {
    let primaryID = routeSelection.applySelection(
      newSelection,
      fallbackPrimaryID: preferredRouteDetailDecisionID
    )
    syncPrimaryDecisionSelection(primaryID)
  }

  private func syncPrimaryDecisionSelection(_ primaryID: String?) {
    if routeSelection.hasActiveMultiSelection(fallbackPrimaryID: preferredRouteDetailDecisionID) {
      state.selectRoute(.decisions)
      state.setRouteDecisionID(primaryID)
      return
    }

    guard let primaryID else {
      if case .route(.decisions) = state.selection {
        state.setRouteDecisionID(nil)
      }
      return
    }

    if case .route(.decisions) = state.selection {
      guard primaryID != state.sectionState.decisionID else { return }
      state.setRouteDecisionID(primaryID)
    } else {
      guard primaryID != state.selection.decisionID else { return }
      state.selectDecision(primaryID)
    }
  }

  private func collapseToRowFromPlainTap(_ decisionID: String) {
    let blocking = currentModifiers.intersection([.command, .shift, .control, .option])
    guard blocking.isEmpty else { return }
    guard hasActiveMultiSelection else { return }
    routeSelection.collapse(to: decisionID)
    syncPrimaryDecisionSelection(decisionID)
  }

  private func collapseSelectionFromApplicationTap(_ signal: SessionPlainClickSignal) {
    let blocking = signal.modifiers.intersection([.command, .shift, .control, .option])
    guard blocking.isEmpty else { return }
    guard hasActiveMultiSelection else { return }
    routeSelection.collapse(to: preferredRouteDetailDecisionID)
  }
}

public struct DecisionDetailSummary: View {
  let decision: Decision
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: SessionWindowRouteContentMetrics {
    SessionWindowRouteContentMetrics(fontScale: fontScale)
  }

  public init(decision: Decision) {
    self.decision = decision
  }

  public var body: some View {
    Form {
      LabeledContent("Summary", value: decision.summary)
      LabeledContent("Rule", value: decision.ruleID)
      LabeledContent("Severity", value: decision.severityRaw)
      if let agentID = decision.agentID {
        LabeledContent("Agent", value: agentID)
      }
      if let taskID = decision.taskID {
        LabeledContent("Task", value: taskID)
      }
    }
    .formStyle(.grouped)
    .padding(metrics.contentPadding)
    .dynamicTypeSize(.xSmall ... .accessibility5)
  }
}
