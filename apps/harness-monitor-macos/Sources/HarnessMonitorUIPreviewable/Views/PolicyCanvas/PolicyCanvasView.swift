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
  @FocusState private var focusedField: PolicyCanvasFocusedField?
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.undoManager) private var undoManager
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

      PolicyCanvasValidationPanel(
        viewModel: viewModel,
        focus: { resolved in
          viewModel.focusIssue(resolved)
        }
      )

      HStack(spacing: 0) {
        PolicyCanvasToolRail(viewModel: viewModel)

        PolicyCanvasViewport(viewModel: viewModel)
          .frame(maxWidth: .infinity, maxHeight: .infinity)

        PolicyCanvasInspector(
          viewModel: viewModel,
          statusLine: statusLine,
          focusedField: $focusedField
        )
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
    // Bind to `pipelineIdentity` so the closure re-fires only when the
    // identity actually flips (nil on first mount, then again when the
    // daemon hands back a loaded pipeline). Without the id binding, the
    // `.optionalID` view-identity flip silently tears down the subtree on
    // the first load, which restarts `.task` mid-flight and re-runs
    // `attachUndoManager` against a half-built environment. Each call is
    // idempotent (bindStatusLine reassigns, attachUndoManager swaps the
    // weak ref, loadPolicyPipeline is gated by
    // `markInitialRemoteLoadRequested`), so a deterministic re-fire is
    // safer than the incidental restart that the identity flip would
    // otherwise cause.
    .task(id: viewModel.pipelineIdentity) {
      bindStatusLine()
      viewModel.attachUndoManager(undoManager)
      await loadPolicyPipeline()
    }
    .onChange(of: dashboardSnapshot) { _, _ in
      applyDashboardSnapshot()
    }
    // `@Environment(\.undoManager)` is window-scoped and may flip when the
    // canvas is reparented (e.g. focus moves between session windows). Re-
    // attach on every change so subsequent `mutate(_:)` calls register
    // against the live manager. Reads inside `.onChange` see the new value.
    .onChange(of: undoManager) { _, newValue in
      viewModel.attachUndoManager(newValue)
    }
    // When the scene leaves .active (Mission Control, Cmd-Tab to another
    // app, modal sheet presentation, window minimize) the in-flight gesture
    // never receives an .onEnded — AppKit cancels the drag silently and the
    // rubber-band curve / port highlight / group highlight stay painted.
    // Enumerating every interruption surface is brittle; clear eagerly on
    // every transition off .active instead.
    .onChange(of: scenePhase) { _, newPhase in
      if newPhase != .active {
        viewModel.clearTransientGestureState()
      }
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

  // Gated on `focusedField == nil`: when the user is editing an inline
  // TextField in the inspector (rename node, group title, edge label, reason
  // code, rule id), Delete/Backspace should target the character in the field,
  // not the selected canvas component; Escape should commit/dismiss the
  // TextField, not clear the canvas selection mid-typing. SwiftUI's text-field
  // first responder consumes these keys natively, so disabling the overlay
  // buttons hands the chord back to the field without an alternate route.
  private var deletionShortcutButtons: some View {
    Group {
      Button("Delete selected policy component") {
        requestDeleteSelectedComponent()
      }
      .keyboardShortcut(.delete, modifiers: [])
      .disabled(focusedField != nil)

      Button("Forward delete selected policy component") {
        requestDeleteSelectedComponent()
      }
      .keyboardShortcut(.deleteForward, modifiers: [])
      .disabled(focusedField != nil)

      Button("Clear policy canvas selection") {
        clearSelectionAndDragState()
      }
      .keyboardShortcut(.escape, modifiers: [])
      .disabled(focusedField != nil)
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
    // Local pre-flight runs before snapshot so the user gets fast feedback on
    // cycles + orphans. Soft warning only — daemon is authoritative, and the
    // snapshot/restore frame around exportDocument() handles rollback on
    // daemon rejection.
    _ = viewModel.runLocalPreflight()
    let snapshot = viewModel.snapshotState()
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
        // Daemon rejected the save; roll local state back to the pre-save
        // snapshot so the chrome and graph reflect what the daemon still
        // believes is the truth. restoreState funnels the status string
        // through one notify call so the inspector line is not racing a
        // second-write override that distorts the user-visible reason.
        viewModel.restoreState(snapshot, reason: "Save rejected, restored previous canvas")
      }
    }
  }

  private func simulate() {
    let snapshot = viewModel.snapshotState()
    let document = viewModel.exportDocument()
    Task { @MainActor in
      let simulated = await store?.simulateTaskBoardPolicyPipeline(document: document) ?? false
      if simulated {
        await forceReloadPolicyPipeline()
      } else {
        viewModel.restoreState(snapshot, reason: "Simulation rejected, restored previous canvas")
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

  /// Escape handler. Cancels any pending deletion confirmation, then clears
  /// the editor's selection and any in-flight drag highlight so the canvas
  /// returns to a quiet idle state. Document-side state is untouched —
  /// `documentDirty` survives Escape because the user's edits are still
  /// pending for the next save.
  private func clearSelectionAndDragState() {
    if pendingDeletionRequest != nil {
      pendingDeletionRequest = nil
      return
    }
    viewModel.clearSelection()
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
