import HarnessMonitorKit
import Observation
import SwiftData
import SwiftUI

private enum InspectorChromeMetrics {
  static let horizontalPadding: CGFloat = 16
  static let verticalPadding: CGFloat = 20
  static let contentSpacing: CGFloat = 16
}

struct InspectorColumnView: View {
  let store: HarnessMonitorStore

  private var resolvedPrimaryContent: InspectorPrimaryContent {
    InspectorPrimaryContent(
      selectedSession: store.selectedSession,
      selectedSessionSummary: store.selectedSessionSummary,
      inspectorSelection: store.inspectorSelection,
      isPersistenceAvailable: store.isPersistenceAvailable
    )
  }

  private var selectedObserver: ObserverSummary? {
    resolvedPrimaryContent.observer
  }

  var body: some View {
    HarnessMonitorColumnScrollView(
      horizontalPadding: InspectorChromeMetrics.horizontalPadding,
      verticalPadding: InspectorChromeMetrics.verticalPadding,
      topScrollEdgeEffect: .hard
    ) {
      VStack(alignment: .leading, spacing: InspectorChromeMetrics.contentSpacing) {
        inspectorPrimaryContent
          .id(resolvedPrimaryContent.identity)
          .transition(.opacity.animation(.easeOut(duration: 0.08)))

        if let detail = store.selectedSession {
          InspectorActionSections(
            store: store,
            detail: detail,
            selectedTask: store.selectedTask,
            selectedAgent: store.selectedAgent,
            selectedObserver: selectedObserver
          )
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .foregroundStyle(HarnessMonitorTheme.ink)
    .textFieldStyle(.roundedBorder)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.inspectorRoot)
  }

  @ViewBuilder private var inspectorPrimaryContent: some View {
    switch resolvedPrimaryContent {
    case .empty:
      InspectorPrimaryEmptyState()
    case .loading(let summary):
      InspectorPrimaryLoadingState(summary: summary)
    case .session(let detail):
      SessionInspectorSummaryCard(detail: detail)
    case .task(let selection):
      TaskInspectorCard(
        store: store,
        task: selection.task,
        notesSessionID: selection.notesSessionID,
        isPersistenceAvailable: selection.isPersistenceAvailable
      )
    case .agent(let selection):
      AgentInspectorCard(
        store: store,
        agent: selection.agent,
        activity: selection.activity
      )
    case .signal(let signal):
      SignalInspectorCard(signal: signal)
    case .observer(let observer):
      ObserverInspectorCard(observer: observer)
    }
  }
}

private struct InspectorPrimaryEmptyState: View {
  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      Text("Inspector")
        .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      Text("Select a session to inspect live task, agent, and signal detail.")
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityTestProbe(
      HarnessMonitorAccessibility.inspectorEmptyState,
      label: "Inspector",
      value: "empty"
    )
  }
}

private struct InspectorPrimaryLoadingState: View {
  let summary: SessionSummary

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      Text("Inspector")
        .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      Text(summary.displayTitle)
        .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
        .italic(summary.title.isEmpty)
        .foregroundStyle(summary.title.isEmpty ? HarnessMonitorTheme.tertiaryInk : HarnessMonitorTheme.ink)
      Text("Loading live task, agent, and signal detail for the selected session.")
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      HarnessMonitorLoadingStateView(title: "Loading session detail")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityTestProbe(
      HarnessMonitorAccessibility.sessionInspectorCard,
      label: "Inspector",
      value: "loading"
    )
    .accessibilityFrameMarker("\(HarnessMonitorAccessibility.sessionInspectorCard).frame")
  }
}

private struct InspectorTaskSelection {
  let task: WorkItem
  let notesSessionID: String?
  let isPersistenceAvailable: Bool
}

private struct InspectorAgentSelection {
  let agent: AgentRegistration
  let activity: AgentToolActivitySummary?
}

private enum InspectorPrimaryContent {
  case empty
  case loading(SessionSummary)
  case session(SessionDetail)
  case task(InspectorTaskSelection)
  case agent(InspectorAgentSelection)
  case signal(SessionSignalRecord)
  case observer(ObserverSummary)

  var identity: String {
    switch self {
    case .empty:
      return "empty"
    case .loading(let summary):
      return "loading:\(summary.sessionId)"
    case .session(let detail):
      return "session:\(detail.session.sessionId)"
    case .task(let selection):
      return "task:\(selection.task.taskId)"
    case .agent(let selection):
      return "agent:\(selection.agent.agentId)"
    case .signal(let signal):
      return "signal:\(signal.signal.signalId)"
    case .observer(let observer):
      return "observer:\(observer.observeId)"
    }
  }

  var observer: ObserverSummary? {
    guard case .observer(let observer) = self else {
      return nil
    }
    return observer
  }

  init(
    selectedSession: SessionDetail?,
    selectedSessionSummary: SessionSummary?,
    inspectorSelection: HarnessMonitorStore.InspectorSelection,
    isPersistenceAvailable: Bool
  ) {
    guard let selectedSession else {
      if let selectedSessionSummary {
        self = .loading(selectedSessionSummary)
      } else {
        self = .empty
      }
      return
    }

    self = Self.resolveSelection(
      selectedSession: selectedSession,
      inspectorSelection: inspectorSelection,
      isPersistenceAvailable: isPersistenceAvailable
    )
  }

  private static func resolveSelection(
    selectedSession: SessionDetail,
    inspectorSelection: HarnessMonitorStore.InspectorSelection,
    isPersistenceAvailable: Bool
  ) -> Self {
    switch inspectorSelection {
    case .none:
      return .session(selectedSession)
    case .task(let taskID):
      guard let task = selectedSession.tasks.first(where: { $0.taskId == taskID }) else {
        return .session(selectedSession)
      }
      return .task(
        InspectorTaskSelection(
          task: task,
          notesSessionID: selectedSession.session.sessionId,
          isPersistenceAvailable: isPersistenceAvailable
        )
      )
    case .agent(let agentID):
      guard let agent = selectedSession.agents.first(where: { $0.agentId == agentID }) else {
        return .session(selectedSession)
      }
      return .agent(
        InspectorAgentSelection(
          agent: agent,
          activity: selectedSession.agentActivity.first(where: { $0.agentId == agent.agentId })
        )
      )
    case .signal(let signalID):
      guard let signal = selectedSession.signals.first(where: { $0.signal.signalId == signalID }) else {
        return .session(selectedSession)
      }
      return .signal(signal)
    case .observer:
      if let observer = selectedSession.observer {
        return .observer(observer)
      }
      return .session(selectedSession)
    }
  }
}

#Preview("Inspector - Session") {
  let store = inspectorPreviewStore(selection: .none)

  InspectorColumnView(store: store)
    .modelContainer(HarnessMonitorPreviewStoreFactory.previewContainer)
    .frame(width: 420, height: 860)
}

#Preview("Inspector - Task") {
  let store = inspectorPreviewStore(selection: .task(PreviewFixtures.tasks[0].taskId))

  InspectorColumnView(store: store)
    .modelContainer(HarnessMonitorPreviewStoreFactory.previewContainer)
    .frame(width: 420, height: 860)
}

#Preview("Inspector - Agent") {
  let store = inspectorPreviewStore(selection: .agent(PreviewFixtures.agents[0].agentId))

  InspectorColumnView(store: store)
    .modelContainer(HarnessMonitorPreviewStoreFactory.previewContainer)
    .frame(width: 420, height: 860)
}

#Preview("Inspector - Observer") {
  let store = inspectorPreviewStore(selection: .observer)

  InspectorColumnView(store: store)
    .modelContainer(HarnessMonitorPreviewStoreFactory.previewContainer)
    .frame(width: 420, height: 860)
}

#Preview("Inspector - Empty") {
  let store = HarnessMonitorPreviewStoreFactory.makeStore(
    for: .dashboardLoaded,
    modelContainer: HarnessMonitorPreviewStoreFactory.previewContainer
  )

  InspectorColumnView(store: store)
    .modelContainer(HarnessMonitorPreviewStoreFactory.previewContainer)
    .frame(width: 420, height: 860)
}

@MainActor
private func inspectorPreviewStore(
  selection: HarnessMonitorStore.InspectorSelection
) -> HarnessMonitorStore {
  let store = HarnessMonitorPreviewStoreFactory.makeStore(
    for: .cockpitLoaded,
    modelContainer: HarnessMonitorPreviewStoreFactory.previewContainer
  )
  store.inspectorSelection = selection
  return store
}
