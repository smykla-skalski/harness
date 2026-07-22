import Foundation
import HarnessMonitorKit
import SwiftUI

struct TaskBoardAutomationPresentationTrigger: Hashable {
  let isActive: Bool
  let snapshotRevision: UInt64?
  let snapshotObservedAt: String?
  let stateRevision: UInt64
  let referenceMinute: Int
  let reconcileIntervalSeconds: UInt64
  let isOnline: Bool
  let isWriteAuthorized: Bool
  let isGloballyBusy: Bool
}

struct TaskBoardAutomationLoadTrigger: Hashable {
  let isActive: Bool
  let isOnline: Bool
  let surface: TaskBoardAutomationInspectorSurface
}

struct TaskBoardAutomationInspector: View {
  let store: HarnessMonitorStore
  let isActive: Bool

  @Environment(\.fontScale)
  var fontScale
  @State private var automationState = TaskBoardAutomationInspectorState()
  @State private var presentationWorker = TaskBoardAutomationInspectorPresentationWorker()
  @State private var cachedPresentationStorage = TaskBoardAutomationPresentation.empty
  @State private var presentedInput: TaskBoardAutomationPresentationInput?
  @State private var presentationGeneration: UInt64 = 0
  @State private var relativeTimeClock = TaskBoardRelativeTimeClock()

  var state: TaskBoardAutomationInspectorState { automationState }
  var cachedPresentation: TaskBoardAutomationPresentation {
    get { cachedPresentationStorage }
    nonmutating set { cachedPresentationStorage = newValue }
  }
  var dashboard: HarnessMonitorStore.ContentDashboardSlice { store.contentUI.dashboard }
  var metrics: TaskBoardOverviewMetrics { TaskBoardOverviewMetrics(fontScale: fontScale) }
  var actions: TaskBoardAutomationInspectorActions {
    TaskBoardAutomationInspectorActions(store: store, state: state, isActive: isActive)
  }

  var presentationInput: TaskBoardAutomationPresentationInput {
    let snapshot = dashboard.taskBoardAutomationSnapshot
    return TaskBoardAutomationPresentationInput(
      snapshot: snapshot,
      runs: state.runs,
      selectedRunID: state.selectedRunID,
      detail: state.detail,
      metrics: state.metrics,
      referenceDate: presentationReferenceDate,
      reconcileIntervalSeconds: reconcileIntervalSeconds,
      isOnline: dashboard.connectionState == .online,
      isWriteAuthorized: isWriteAuthorized,
      isGloballyBusy: dashboard.isBusy
    )
  }

  var isPresentationCurrent: Bool {
    isActive && presentedInput == presentationInput
  }

  var body: some View {
    let input = presentationInput
    let presentationTrigger = TaskBoardAutomationPresentationTrigger(
      isActive: isActive,
      snapshotRevision: input.snapshot?.revision,
      snapshotObservedAt: input.snapshot?.observedAt,
      stateRevision: state.presentationRevision,
      referenceMinute: Int(input.referenceDate.timeIntervalSince1970 / 60),
      reconcileIntervalSeconds: input.reconcileIntervalSeconds,
      isOnline: input.isOnline,
      isWriteAuthorized: input.isWriteAuthorized,
      isGloballyBusy: input.isGloballyBusy,
    )

    TaskBoardSection(title: "Automation") {
      HarnessMonitorSegmentedPicker(
        title: "Automation inspector surface",
        selection: Binding(
          get: { state.surface },
          set: { state.surface = $0 }
        ),
        accessibilityIdentifier: "harness.task-board.automation.surface",
        fillsWidth: true
      ) {
        ForEach(TaskBoardAutomationInspectorSurface.stableAllCases) { surface in
          Text(surface.title).tag(surface)
        }
      }

      surfaceContent(isPresentationCurrent: presentedInput == input && isActive)
    }
    .environment(
      \.taskBoardOperationsRowLabelFont,
      HarnessMonitorTextSize.scaledFont(.body, by: fontScale)
    )
    .environment(\.taskBoardOperationsRowLabelWidth, 104 * min(fontScale, 1.3))
    .task(id: presentationTrigger) {
      guard isActive else { return }
      await rebuildPresentation(input: input)
    }
    .task(
      id: TaskBoardAutomationLoadTrigger(
        isActive: isActive,
        isOnline: input.isOnline,
        surface: state.surface
      )
    ) {
      if input.isOnline {
        actions.enqueueVisibleLoads()
      } else {
        state.resetRemoteData()
      }
    }
    .task(id: isActive) {
      guard isActive else { return }
      await relativeTimeClock.run()
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.automation")
  }

  @ViewBuilder
  private func surfaceContent(isPresentationCurrent: Bool) -> some View {
    switch state.surface {
    case .automation:
      TaskBoardAutomationStatusView(
        presentation: cachedPresentation,
        metrics: metrics,
        isPresentationCurrent: isPresentationCurrent
      )
    case .manual:
      TaskBoardAutomationManualView(
        presentation: cachedPresentation,
        metrics: metrics,
        isPresentationCurrent: isPresentationCurrent,
        activeAction: state.activeAction,
        actions: actions
      )
    case .history:
      TaskBoardAutomationHistoryView(
        presentation: cachedPresentation,
        metrics: metrics,
        selectedRunID: state.selectedRunID,
        historyLoad: state.historyLoad,
        isDetailLoading: state.isDetailLoading,
        isMetricsLoading: state.isMetricsLoading,
        hasOlder: state.hasOlder,
        isDetailAuthorized: isWriteAuthorized,
        actions: actions
      )
    }
  }

  @MainActor
  private func rebuildPresentation(
    input: TaskBoardAutomationPresentationInput
  ) async {
    presentationGeneration &+= 1
    let generation = presentationGeneration
    let presentation = await presentationWorker.compute(input: input)
    guard !Task.isCancelled, presentationGeneration == generation else { return }
    if cachedPresentation != presentation {
      cachedPresentation = presentation
    }
    presentedInput = input
  }

  private var reconcileIntervalSeconds: UInt64 {
    dashboard.taskBoardOrchestratorStatus?.settings.scheduling.reconcileIntervalSeconds ?? 60
  }

  private var presentationReferenceDate: Date {
    let minute = floor(relativeTimeClock.referenceDate.timeIntervalSince1970 / 60)
    return Date(timeIntervalSince1970: minute * 60)
  }

  var isWriteAuthorized: Bool {
    guard let profile = store.remoteDaemonProfile else { return true }
    return profile.status == .active
      && profile.role != .viewer
      && profile.scopes.contains("write")
  }

}
