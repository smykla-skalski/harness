import HarnessMonitorKit
import SwiftUI

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
