import HarnessMonitorKit
import SwiftUI

private enum InspectorChromeMetrics {
  static let horizontalPadding: CGFloat = 16
  static let verticalPadding: CGFloat = 20
  static let contentSpacing: CGFloat = 16
}

private enum InspectorPrimaryResetKey: Hashable {
  case task(taskID: String, notesSessionID: String?)
  case agent(agentID: String)
}

struct InspectorColumnView: View {
  let store: HarnessMonitorStore
  let inspectorUI: HarnessMonitorStore.InspectorUISlice

  var body: some View {
    HarnessMonitorColumnScrollView(
      horizontalPadding: InspectorChromeMetrics.horizontalPadding,
      verticalPadding: InspectorChromeMetrics.verticalPadding,
      topScrollEdgeEffect: .hard
    ) {
      VStack(alignment: .leading, spacing: InspectorChromeMetrics.contentSpacing) {
        inspectorPrimaryContent

        if let actionContext = inspectorUI.actionContext {
          InspectorActionSections(
            store: store,
            context: actionContext
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
    switch inspectorUI.primaryContent {
    case .empty:
      InspectorPrimaryEmptyState()
    case .loading(let summary):
      InspectorPrimaryLoadingState(summary: summary)
        .transition(.opacity.animation(.easeOut(duration: 0.08)))
    case .session(let detail):
      SessionInspectorSummaryCard(detail: detail)
        .transition(.opacity.animation(.easeOut(duration: 0.08)))
    case .task(let selection):
      TaskInspectorCard(
        store: store,
        task: selection.task,
        notesSessionID: selection.notesSessionID,
        isPersistenceAvailable: selection.isPersistenceAvailable
      )
      .id(
        InspectorPrimaryResetKey.task(
          taskID: selection.task.taskId,
          notesSessionID: selection.notesSessionID
        )
      )
      .transition(.opacity.animation(.easeOut(duration: 0.08)))
    case .agent(let selection):
      AgentInspectorCard(
        store: store,
        agent: selection.agent,
        activity: selection.activity
      )
      .id(InspectorPrimaryResetKey.agent(agentID: selection.agent.agentId))
      .transition(.opacity.animation(.easeOut(duration: 0.08)))
    case .signal(let signal):
      SignalInspectorCard(signal: signal)
        .transition(.opacity.animation(.easeOut(duration: 0.08)))
    case .observer(let observer):
      ObserverInspectorCard(observer: observer)
        .transition(.opacity.animation(.easeOut(duration: 0.08)))
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
        .foregroundStyle(
          summary.title.isEmpty ? HarnessMonitorTheme.tertiaryInk : HarnessMonitorTheme.ink)
      Text("Loading live task, agent, and signal detail for the selected session.")
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityTestProbe(
      HarnessMonitorAccessibility.inspectorLoadingState,
      label: "Inspector",
      value: "loading"
    )
    .accessibilityFrameMarker("\(HarnessMonitorAccessibility.inspectorLoadingState).frame")
  }
}

#Preview("Inspector - Session") {
  let store = inspectorPreviewStore(selection: .none)

  InspectorColumnView(
    store: store,
    inspectorUI: store.inspectorUI
  )
  .modelContainer(HarnessMonitorPreviewStoreFactory.previewContainer)
  .frame(width: 420, height: 860)
}

#Preview("Inspector - Task") {
  let store = inspectorPreviewStore(selection: .task(PreviewFixtures.tasks[0].taskId))

  InspectorColumnView(
    store: store,
    inspectorUI: store.inspectorUI
  )
  .modelContainer(HarnessMonitorPreviewStoreFactory.previewContainer)
  .frame(width: 420, height: 860)
}

#Preview("Inspector - Agent") {
  let store = inspectorPreviewStore(selection: .agent(PreviewFixtures.agents[0].agentId))

  InspectorColumnView(
    store: store,
    inspectorUI: store.inspectorUI
  )
  .modelContainer(HarnessMonitorPreviewStoreFactory.previewContainer)
  .frame(width: 420, height: 860)
}

#Preview("Inspector - Observer") {
  let store = inspectorPreviewStore(selection: .observer)

  InspectorColumnView(
    store: store,
    inspectorUI: store.inspectorUI
  )
  .modelContainer(HarnessMonitorPreviewStoreFactory.previewContainer)
  .frame(width: 420, height: 860)
}

#Preview("Inspector - Empty") {
  let store = HarnessMonitorPreviewStoreFactory.makeStore(
    for: .dashboardLoaded,
    modelContainer: HarnessMonitorPreviewStoreFactory.previewContainer
  )

  InspectorColumnView(
    store: store,
    inspectorUI: store.inspectorUI
  )
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
