import HarnessMonitorKit
import SwiftUI

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
  static let labRemoteActionDisabledReason = "Disabled in Policy Canvas Lab"
  static let missingStoreRemoteActionDisabledReason =
    "Unavailable without a live policy store"
  @State private var viewModelState: PolicyCanvasViewModel
  @State private var isShowingPromoteConfirmationState = false
  @State private var pendingDeletionRequestState: PolicyCanvasDeletionRequest?
  @State private var statusLineState: String = "No pending changes"
  @State private var searchPaletteVisibleState: Bool = false
  @State private var isAutomationPolicySheetPresentedState = false
  @State private var presentedEditSheetState: PolicyCanvasEditSheet?
  @State private var automationPolicyCenterState = AutomationPolicyCenter.shared
  @State private var selectionFocusRequestState: PolicyCanvasViewportSelectionFocusRequest?
  @State private var selectionFocusRequestIDState: UInt64 = 0
  /// User-facing override for the simulation overlay. Defaults to nil
  /// (auto-show whenever a simulation exists and the user is on the
  /// simulation tab); the chrome toggle in the top bar flips this to
  /// `true`/`false` so the user can hide noise while staying on the
  /// simulation tab, or pin the overlay while reviewing the draft tab.
  ///
  /// Simulation visibility is purely view state — never marks
  /// `documentDirty`. Holding the override in @State (not in the view
  /// model) keeps document state separate from per-window viewport
  /// preferences, matching how the rest of the canvas treats zoom and
  /// inspector visibility.
  @State private var simulationOverlayOverrideState: Bool?
  @FocusState var focusedFieldState: PolicyCanvasFocusedField?
  /// VoiceOver focus anchor for the canvas surface. The search palette writes
  /// the just-selected component into this binding after dismiss so VO lands
  /// on the destination node/edge/group instead of the empty space where the
  /// palette used to be. Node/edge/group views downstream apply
  /// `.accessibilityFocused($focusedComponent, equals: ...)` to receive the
  /// shift; 3G's broader a11y focus plumbing will subsume this anchor at
  /// integration time.
  @AccessibilityFocusState var focusedComponentState: PolicyCanvasSelection?
  @Environment(\.scenePhase)
  var scenePhase
  @Environment(\.undoManager)
  var undoManager
  /// P19 root-side system reduce-motion read; rebound onto
  /// `\.policyCanvasReducedMotion` for nested layers (Wave 4K).
  @Environment(\.accessibilityReduceMotion)
  var systemReduceMotion

  /// Scene-scoped storage for viewport state (zoom, selection, scroll
  /// position) keyed by pipeline identity. Before this commit each viewport
  /// field had its own `@SceneStorage` key (`policyCanvas.zoom`,
  /// `policyCanvas.selectionRaw`, ...) — but those keys are scene-scoped,
  /// NOT pipeline-scoped, so two windows on the same scene viewing
  /// different pipelines would stomp each other's last-write. The single
  /// JSON-encoded map below is keyed by `pipelineIdentity`, so each pipeline
  /// gets its own slot.
  ///
  /// `pipelineIdentity == nil` (no document yet) skips persistence entirely
  /// - two trace-less pipelines must not share viewport state through a
  /// shared sentinel key. Module-internal access so
  /// `PolicyCanvasView+SceneStorage.swift` can read/write the storage from
  /// its extension; the host view struct is only constructable from the same
  /// module so this is not API surface.
  @SceneStorage("policyCanvas.byPipeline")
  var storedPipelineStateRawState: String = ""
  let store: HarnessMonitorStore?
  let dashboardUI: HarnessMonitorStore.ContentDashboardSlice?
  let suppressesAutosave: Bool
  let suppressesSceneStorage: Bool
  let allowsRemoteActions: Bool
  let sceneFocusEnabled: Bool

  var viewModel: PolicyCanvasViewModel {
    viewModelState
  }

  var statusLine: String {
    get { statusLineState }
    nonmutating set { statusLineState = newValue }
  }

  var pendingDeletionRequest: PolicyCanvasDeletionRequest? {
    get { pendingDeletionRequestState }
    nonmutating set { pendingDeletionRequestState = newValue }
  }

  var isShowingPromoteConfirmation: Bool {
    get { isShowingPromoteConfirmationState }
    nonmutating set { isShowingPromoteConfirmationState = newValue }
  }

  var searchPaletteVisible: Bool {
    get { searchPaletteVisibleState }
    nonmutating set { searchPaletteVisibleState = newValue }
  }

  var isAutomationPolicySheetPresented: Bool {
    get { isAutomationPolicySheetPresentedState }
    nonmutating set { isAutomationPolicySheetPresentedState = newValue }
  }

  var presentedEditSheet: PolicyCanvasEditSheet? {
    get { presentedEditSheetState }
    nonmutating set { presentedEditSheetState = newValue }
  }

  var automationPolicyCenter: AutomationPolicyCenter {
    automationPolicyCenterState
  }

  var selectionFocusRequest: PolicyCanvasViewportSelectionFocusRequest? {
    get { selectionFocusRequestState }
    nonmutating set { selectionFocusRequestState = newValue }
  }

  var selectionFocusRequestID: UInt64 {
    get { selectionFocusRequestIDState }
    nonmutating set { selectionFocusRequestIDState = newValue }
  }

  var simulationOverlayOverride: Bool? {
    get { simulationOverlayOverrideState }
    nonmutating set { simulationOverlayOverrideState = newValue }
  }

  var focusedField: PolicyCanvasFocusedField? {
    focusedFieldState
  }

  var storedPipelineStateRaw: String {
    get { storedPipelineStateRawState }
    nonmutating set { storedPipelineStateRawState = newValue }
  }

  public init() {
    _viewModelState = State(initialValue: .sample())
    self.store = nil
    self.dashboardUI = nil
    suppressesAutosave = false
    suppressesSceneStorage = false
    allowsRemoteActions = true
    sceneFocusEnabled = true
  }

  @MainActor
  public init(
    store: HarnessMonitorStore,
    dashboardUI: HarnessMonitorStore.ContentDashboardSlice,
    suppressesAutosave: Bool = false,
    suppressesSceneStorage: Bool = false,
    allowsRemoteActions: Bool = true,
    sceneFocusEnabled: Bool = true
  ) {
    _viewModelState = State(
      initialValue: PolicyCanvasViewModel.liveStartupState(
        document: dashboardUI.taskBoardPolicyPipeline,
        simulation: dashboardUI.taskBoardPolicySimulation,
        audit: dashboardUI.taskBoardPolicyAudit,
        activeCanvasId: dashboardUI.taskBoardPolicyCanvasWorkspace?.activeCanvasId
      )
    )
    self.store = store
    self.dashboardUI = dashboardUI
    self.suppressesAutosave = suppressesAutosave
    self.suppressesSceneStorage = suppressesSceneStorage
    self.allowsRemoteActions = allowsRemoteActions
    self.sceneFocusEnabled = sceneFocusEnabled
  }

  init(viewModel: PolicyCanvasViewModel) {
    _viewModelState = State(initialValue: viewModel)
    self.store = nil
    self.dashboardUI = nil
    suppressesAutosave = false
    suppressesSceneStorage = false
    allowsRemoteActions = true
    sceneFocusEnabled = true
  }

  init(
    viewModel: PolicyCanvasViewModel,
    store: HarnessMonitorStore,
    dashboardUI: HarnessMonitorStore.ContentDashboardSlice,
    suppressesAutosave: Bool = false,
    suppressesSceneStorage: Bool = false,
    allowsRemoteActions: Bool = true,
    sceneFocusEnabled: Bool = true
  ) {
    _viewModelState = State(initialValue: viewModel)
    self.store = store
    self.dashboardUI = dashboardUI
    self.suppressesAutosave = suppressesAutosave
    self.suppressesSceneStorage = suppressesSceneStorage
    self.allowsRemoteActions = allowsRemoteActions
    self.sceneFocusEnabled = sceneFocusEnabled
  }

  public var body: some View {
    let _ = HarnessMonitorPerfTrace.countBodyEval("PolicyCanvasView")
    policyCanvasSplitLayout
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
      .frame(minHeight: 620)
      .background(PolicyCanvasVisualStyle.rootBackground)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasRoot)
      .sheet(isPresented: $isAutomationPolicySheetPresentedState) {
        PolicyCanvasAutomationPolicySheet(viewModel: viewModel)
      }
      .sheet(item: $presentedEditSheetState) { sheet in
        PolicyCanvasEditSheetView(
          viewModel: viewModel,
          statusLine: statusLine,
          sheet: sheet,
          dismiss: { presentedEditSheet = nil }
        )
      }
      // P19: rebind to a canvas-scoped key so nested layers (incl. 4K) read
      // one handle. See `PolicyCanvasMotion.swift` for the helper contract.
      .environment(\.policyCanvasReducedMotion, systemReduceMotion)
      .overlay(alignment: .topLeading) {
        deletionShortcutButtons
      }
      .overlay(alignment: .topLeading) {
        searchShortcutButtons
      }
      .overlay(alignment: .topLeading) {
        editShortcutButtons
      }
      // `.onKeyPress`-based handler attached as a modifier so the responder
      // chain owns the chord matching directly — no hidden Buttons walking
      // the responder list on every keypress.
      .policyCanvasPowerEditShortcuts(
        viewModel: viewModel,
        focusedField: $focusedFieldState
      )
      .overlay(alignment: .topTrailing) {
        if searchPaletteVisible {
          PolicyCanvasSearchPalette(
            viewModel: viewModel,
            isVisible: $searchPaletteVisibleState,
            postCommitFocus: $focusedComponentState
          )
        }
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
        bindAutosaveTrigger()
        restoreSceneStorageIfNeeded()
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
      .onChange(of: viewModel.pipelineIdentity) { _, _ in
        // First time the pipeline identity becomes known, try to restore the
        // scene storage. Subsequent same-id republishes leave the stored
        // viewport alone - the user's in-window state always wins. The
        // by-pipeline JSON map is keyed by identity, so there's no separate
        // stamp to apply - lookups happen at read time.
        restoreSceneStorageIfNeeded()
      }
      .onChange(of: viewModel.zoom) { _, newZoom in
        persistSceneStorageIfNeeded(zoom: Double(newZoom))
      }
      .onChange(of: viewModel.selection) { _, newSelection in
        persistSceneStorageIfNeeded(selection: newSelection)
      }
      // When the scene leaves .active (Mission Control, Cmd-Tab to another
      // app, modal sheet presentation, window minimize) the in-flight gesture
      // never receives an .onEnded — AppKit cancels the drag silently and the
      // rubber-band curve / port highlight / group highlight stay painted.
      // Enumerating every interruption surface is brittle; clear eagerly on
      // every transition off .active instead.
      //
      // .background specifically (window closed/hidden, app moving to back)
      // also tears down any pending autosave Task with the scene - the last
      // 1.5s of edits would otherwise vanish silently. Flush them by spawning
      // a save Task synchronously so the daemon round-trip starts before the
      // scene actually drops. macOS gives the app a short window to do work
      // when entering .background; the Task may not complete before the scene
      // dies, but starting it is the most we can do without a dedicated
      // app-level lifecycle hook.
      .onChange(of: scenePhase) { _, newPhase in
        if newPhase != .active {
          viewModel.clearTransientGestureState()
        }
        if newPhase == .background, !suppressesAutosave, remoteActionsEnabled,
          viewModel.documentDirty,
          viewModel.autosaveTask != nil
        {
          flushPendingAutosaveBeforeBackground()
        }
      }
      .confirmationDialog(
        "Promote policy pipeline?",
        isPresented: $isShowingPromoteConfirmationState,
        titleVisibility: .visible
      ) {
        Button("Promote", role: .destructive) {
          confirmPromote()
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("The saved revision will become the enforced automation policy")
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

  var deletionConfirmationPresented: Binding<Bool> {
    Binding(
      get: { pendingDeletionRequest != nil },
      set: { isPresented in
        if !isPresented {
          pendingDeletionRequest = nil
        }
      }
    )
  }

  func loadPolicyPipeline() async {
    guard let store else {
      return
    }
    if dashboardUI?.taskBoardPolicyPipeline != nil {
      applyDashboardSnapshot()
      return
    }
    // Live app startup does not defer the dashboard window until bootstrap, so
    // the first Policies visit can arrive before the daemon client exists.
    await store.bootstrapIfNeeded()
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

}
