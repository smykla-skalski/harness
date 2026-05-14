import HarnessMonitorKit
import SwiftUI

private struct DashboardCanvasSnapshot: Equatable {
  let document: TaskBoardPolicyPipelineDocument?
  let simulation: TaskBoardPolicyPipelineSimulationResult?
  let audit: TaskBoardPolicyPipelineAuditSummary?
}

extension View {
  /// Apply `.id(_:)` only when `value` is non-nil. The branch fires exactly
  /// once per pipeline load (nil to id), which is the intended identity reset
  /// point. Same-id re-renders share identity; nil-to-nil renders never break
  /// it. Do not use this for ids that flip mid-session — that would tear down
  /// local @State on every flip.
  @ViewBuilder
  fileprivate func optionalID<ID: Hashable>(_ value: ID?) -> some View {
    if let value {
      self.id(value)
    } else {
      self
    }
  }
}

public struct PolicyCanvasView: View {
  @State private var viewModel: PolicyCanvasViewModel
  @State private var isShowingPromoteConfirmation = false
  @State private var pendingDeletionRequest: PolicyCanvasDeletionRequest?
  @State private var statusLine: String = "No pending changes"
  private let store: HarnessMonitorStore?
  private let dashboardUI: HarnessMonitorStore.ContentDashboardSlice?

  public init() {
    _viewModel = State(initialValue: .sample())
    self.store = nil
    self.dashboardUI = nil
  }

  public init(
    store: HarnessMonitorStore,
    dashboardUI: HarnessMonitorStore.ContentDashboardSlice
  ) {
    _viewModel = State(initialValue: .sample())
    self.store = store
    self.dashboardUI = dashboardUI
  }

  init(viewModel: PolicyCanvasViewModel) {
    _viewModel = State(initialValue: viewModel)
    self.store = nil
    self.dashboardUI = nil
  }

  init(
    viewModel: PolicyCanvasViewModel,
    store: HarnessMonitorStore,
    dashboardUI: HarnessMonitorStore.ContentDashboardSlice
  ) {
    _viewModel = State(initialValue: viewModel)
    self.store = store
    self.dashboardUI = dashboardUI
  }

  public var body: some View {
    VStack(spacing: 0) {
      PolicyCanvasTopBar(
        viewModel: viewModel,
        canPromote: viewModel.canPromote,
        save: saveDraft,
        simulate: simulate,
        promote: requestPromote
      )

      HStack(spacing: 0) {
        PolicyCanvasToolRail(viewModel: viewModel)

        PolicyCanvasViewport(viewModel: viewModel)
          .frame(maxWidth: .infinity, maxHeight: .infinity)

        PolicyCanvasInspector(viewModel: viewModel, statusLine: statusLine)
          .frame(width: 280)
      }
    }
    // Reset the canvas subview tree (gesture origins, hover, focus) only when
    // the underlying pipeline switches. Same-pipeline re-renders preserve
    // local @State; the host PolicyCanvasView's @State (viewModel, statusLine)
    // is owned one level up and survives across pipeline switches.
    //
    // Before any pipeline loads, `pipelineIdentity` is nil and `optionalID`
    // skips the `.id()` modifier entirely. This avoids collapsing two distinct
    // trace-less pipelines onto a shared "default" id (which would blow
    // gesture state across pipelines). The single nil→non-nil flip on first
    // load resets local @State once, matching the load semantics.
    .optionalID(viewModel.pipelineIdentity)
    .frame(minWidth: 980, minHeight: 620)
    .background(Color(red: 0.05, green: 0.06, blue: 0.08))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasRoot)
    .overlay(alignment: .topLeading) {
      deletionShortcutButtons
    }
    .task {
      bindStatusLine()
      await loadPolicyPipeline()
    }
    .onChange(of: dashboardSnapshot) { _, _ in
      applyDashboardSnapshot()
    }
    .confirmationDialog(
      "Promote policy pipeline?",
      isPresented: $isShowingPromoteConfirmation,
      titleVisibility: .visible
    ) {
      Button("Promote", role: .destructive) {
        confirmPromote()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The saved revision will become the enforced automation policy.")
    }
    .confirmationDialog(
      pendingDeletionRequest?.title ?? "Delete policy component?",
      isPresented: deletionConfirmationPresented,
      titleVisibility: .visible,
      presenting: pendingDeletionRequest
    ) { request in
      Button(request.confirmationTitle, role: .destructive) {
        viewModel.confirmDelete(request)
        pendingDeletionRequest = nil
      }
      Button("Cancel", role: .cancel) {}
    } message: { request in
      Text(request.message)
    }
  }

  private var deletionShortcutButtons: some View {
    Group {
      Button("Delete selected policy component") {
        requestDeleteSelectedComponent()
      }
      .keyboardShortcut(.delete, modifiers: [])

      Button("Forward delete selected policy component") {
        requestDeleteSelectedComponent()
      }
      .keyboardShortcut(.deleteForward, modifiers: [])
    }
    .opacity(0)
    .frame(width: 0, height: 0)
    .accessibilityHidden(true)
  }

  private var deletionConfirmationPresented: Binding<Bool> {
    Binding(
      get: { pendingDeletionRequest != nil },
      set: { isPresented in
        if !isPresented {
          pendingDeletionRequest = nil
        }
      }
    )
  }

  private func loadPolicyPipeline() async {
    guard let store else {
      return
    }
    if dashboardUI?.taskBoardPolicyPipeline != nil {
      applyDashboardSnapshot()
      return
    }
    guard viewModel.markInitialRemoteLoadRequested() else {
      return
    }
    await store.refreshTaskBoardPolicyPipeline()
    applyDashboardSnapshot()
  }

  /// Hashable snapshot of the dashboard slices that feed the canvas. Changing
  /// any of the three fields triggers a single `.onChange` instead of two
  /// separate `.onChange` blocks that both clobbered local edits.
  private var dashboardSnapshot: DashboardCanvasSnapshot {
    DashboardCanvasSnapshot(
      document: dashboardUI?.taskBoardPolicyPipeline,
      simulation: dashboardUI?.taskBoardPolicySimulation,
      audit: dashboardUI?.taskBoardPolicyAudit
    )
  }

  private func applyDashboardSnapshot() {
    viewModel.load(
      document: dashboardUI?.taskBoardPolicyPipeline,
      simulation: dashboardUI?.taskBoardPolicySimulation,
      audit: dashboardUI?.taskBoardPolicyAudit
    )
  }

  private func saveDraft() {
    let document = viewModel.exportDocument()
    Task { @MainActor in
      let saved = await store?.saveTaskBoardPolicyPipelineDraft(document: document) ?? false
      if saved {
        // Don't pre-clear documentDirty across the upcoming await. MainActor
        // serializes turns, not the gap between awaits: a dashboard publish
        // running between the clear and the refresh's return would take the
        // clean branch and clobber edits the user made during the save. Let
        // load() clear dirty when the post-save refresh applies the new
        // backingDocument on its own clean-incoming branch.
        await forceReloadPolicyPipeline()
      } else {
        statusLine = "Save blocked by validation"
      }
    }
  }

  private func simulate() {
    let document = viewModel.exportDocument()
    Task { @MainActor in
      let simulated = await store?.simulateTaskBoardPolicyPipeline(document: document) ?? false
      if simulated {
        await forceReloadPolicyPipeline()
      } else {
        statusLine = "Simulation failed"
      }
    }
  }

  private func requestPromote() {
    guard viewModel.canPromote, let revision = viewModel.backingDocument?.revision else {
      statusLine = "Promote requires a saved matching simulation"
      return
    }
    statusLine = "Confirm promotion for revision \(revision)"
    isShowingPromoteConfirmation = true
  }

  private func confirmPromote() {
    guard viewModel.canPromote, let revision = viewModel.backingDocument?.revision else {
      statusLine = "Promote requires a saved matching simulation"
      return
    }
    Task { @MainActor in
      let promoted = await store?.promoteTaskBoardPolicyPipeline(revision: revision) ?? false
      if promoted {
        await forceReloadPolicyPipeline()
      } else {
        statusLine = "Promotion blocked"
      }
    }
  }

  private func requestDeleteSelectedComponent() {
    pendingDeletionRequest = viewModel.deleteSelectedComponent()
  }

  private func forceReloadPolicyPipeline() async {
    guard let store else {
      return
    }
    await store.refreshTaskBoardPolicyPipeline()
    applyDashboardSnapshot()
  }

  /// Bind the view model's status callback to the local `@State` status line.
  /// Captured `_statusLine` is reference-backed by SwiftUI, so closure writes
  /// land in the same storage even though the view struct is a value.
  private func bindStatusLine() {
    viewModel.statusCallback = { @MainActor newStatus in
      statusLine = newStatus
    }
  }
}
