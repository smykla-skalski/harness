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
  @State private var presentationWorker = SessionRouteListPresentationWorker()
  @State private var cachedPresentation = SessionTaskListPresentation.empty
  @State private var presentationGeneration: UInt64 = 0

  private var metrics: SessionWindowRouteContentMetrics {
    SessionWindowRouteContentMetrics(fontScale: fontScale)
  }

  private var preferredRouteDetailTaskID: String? {
    if case .route(.tasks) = state.selection {
      return SessionTaskRouteSelectionPolicy.preferredRouteDetailTaskID(
        rememberedTaskID: state.sectionState.taskID,
        visibleTaskIDs: cachedPresentation.taskIDs
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

  private var presentationInput: SessionTaskListPresentationInput {
    SessionTaskListPresentationInput(
      tasks: detail?.tasks ?? [],
      query: appSearchModel?.query ?? ""
    )
  }

  var body: some View {
    let tasks = cachedPresentation.tasks
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
                    orderedVisibleIDs: cachedPresentation.taskIDs
                  )
                )
              )
            }
          }
        } else if cachedPresentation.hasQuery {
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
    .task(id: presentationInput) {
      await rebuildPresentation(input: presentationInput)
    }
    .onChange(of: cachedPresentation.taskIDs) { _, ids in
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
