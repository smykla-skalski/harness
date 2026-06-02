import HarnessMonitorKit
import SwiftUI

public struct PolicyCanvasView: View {
  static let labRemoteActionDisabledReason = "Disabled in Policy Canvas Lab"
  static let missingStoreRemoteActionDisabledReason =
    "Unavailable without a live policy store"
  @State private var viewModelState: PolicyCanvasViewModel
  @State private var isShowingPromoteConfirmationState = false
  @State private var pendingDeletionRequestState: PolicyCanvasDeletionRequest?
  @State private var statusLineState: String = "No pending changes"
  @State private var searchPaletteVisibleState: Bool = false
  @State private var presentedEditSheetState: PolicyCanvasEditSheet?
  @State private var selectionFocusRequestState: PolicyCanvasViewportSelectionFocusRequest?
  @State private var selectionFocusRequestIDState: UInt64 = 0
  @FocusState var canvasKeyboardFocusedState: Bool
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

  /// Autosave debounce window (seconds) from Settings > Policies > Canvas. `0`
  /// is Off — `bindAutosaveTrigger()` then leaves the trigger unbound so timed
  /// autosave never fires (Cmd+S and the scene-background flush still save).
  /// Read through the `autosaveDebounceSeconds` computed property so the
  /// `+Support` extension can gate on it.
  @AppStorage(PolicyCanvasAutosaveDefaults.debounceSecondsKey)
  private var autosaveDebounceSecondsState = PolicyCanvasAutosaveDefaults.defaultDebounceSeconds
  @AppStorage(PolicyCanvasWorkflowStatusDefaults.isVisibleKey)
  private var workflowStatusVisibleState = PolicyCanvasWorkflowStatusDefaults.isVisibleDefault

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
  let runtime: (any PolicyCanvasEditorRuntime)?
  let dashboardSnapshotOverride: DashboardCanvasSnapshot?
  let suppressesAutosave: Bool
  let suppressesSceneStorage: Bool
  let allowsRemoteActions: Bool
  let sceneFocusEnabled: Bool
  let automationStore: PolicyCanvasAutomationStore

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

  var presentedEditSheet: PolicyCanvasEditSheet? {
    get { presentedEditSheetState }
    nonmutating set { presentedEditSheetState = newValue }
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

  var autosaveDebounceSeconds: Int {
    autosaveDebounceSecondsState
  }

  var workflowStatusVisible: Bool {
    get { workflowStatusVisibleState }
    nonmutating set { workflowStatusVisibleState = newValue }
  }

  public init() {
    _viewModelState = State(initialValue: .sample())
    self.runtime = nil
    dashboardSnapshotOverride = nil
    suppressesAutosave = false
    suppressesSceneStorage = false
    allowsRemoteActions = true
    sceneFocusEnabled = true
    automationStore = .shared
  }

  @MainActor
  public init(
    runtime: any PolicyCanvasEditorRuntime,
    dashboardSnapshotOverride: PolicyCanvasHostSnapshot? = nil,
    suppressesAutosave: Bool = false,
    suppressesSceneStorage: Bool = false,
    allowsRemoteActions: Bool = true,
    sceneFocusEnabled: Bool = true,
    automationStore: PolicyCanvasAutomationStore = .shared
  ) {
    let snapshot = dashboardSnapshotOverride ?? runtime.policyCanvasSnapshot
    _viewModelState = State(
      initialValue: PolicyCanvasViewModel.liveStartupState(
        document: snapshot.document,
        simulation: snapshot.simulation,
        audit: snapshot.audit,
        activeCanvasId: snapshot.activeCanvasId
      )
    )
    self.runtime = runtime
    self.dashboardSnapshotOverride = dashboardSnapshotOverride
    self.suppressesAutosave = suppressesAutosave
    self.suppressesSceneStorage = suppressesSceneStorage
    self.allowsRemoteActions = allowsRemoteActions
    self.sceneFocusEnabled = sceneFocusEnabled
    self.automationStore = automationStore
  }

  init(
    viewModel: PolicyCanvasViewModel,
    runtime: (any PolicyCanvasEditorRuntime)? = nil,
    automationStore: PolicyCanvasAutomationStore = .shared
  ) {
    _viewModelState = State(initialValue: viewModel)
    self.runtime = runtime
    dashboardSnapshotOverride = nil
    suppressesAutosave = false
    suppressesSceneStorage = false
    allowsRemoteActions = true
    sceneFocusEnabled = true
    self.automationStore = automationStore
  }

  public init(
    viewModel: PolicyCanvasViewModel,
    runtime: any PolicyCanvasEditorRuntime,
    dashboardSnapshotOverride: PolicyCanvasHostSnapshot? = nil,
    suppressesAutosave: Bool = false,
    suppressesSceneStorage: Bool = false,
    allowsRemoteActions: Bool = true,
    sceneFocusEnabled: Bool = true,
    automationStore: PolicyCanvasAutomationStore = .shared
  ) {
    _viewModelState = State(initialValue: viewModel)
    self.runtime = runtime
    self.dashboardSnapshotOverride = dashboardSnapshotOverride
    self.suppressesAutosave = suppressesAutosave
    self.suppressesSceneStorage = suppressesSceneStorage
    self.allowsRemoteActions = allowsRemoteActions
    self.sceneFocusEnabled = sceneFocusEnabled
    self.automationStore = automationStore
  }

  public var body: some View {
    let _ = HarnessMonitorPerfTrace.countBodyEval("PolicyCanvasView")
    policyCanvasSplitLayout
      .focusable()
      .focusEffectDisabled()
      .focused($canvasKeyboardFocusedState)
      .frame(minHeight: 620)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasRoot)
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
        focusedField: $focusedFieldState,
        isEnabled: sceneFocusEnabled
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
      // Run startup/load wiring once. Pipeline switches must mutate the existing
      // canvas in place so cached tab changes do not tear down the viewport,
      // restart load work, or rebuild local SwiftUI state before first paint.
      .task {
        bindStatusLine()
        viewModel.attachUndoManager(undoManager)
        bindAutosaveTrigger()
        restoreSceneStorageIfNeeded()
        await loadPolicyPipeline()
      }
      .onChange(of: dashboardSnapshot) { _, _ in
        applyDashboardSnapshot()
      }
      .onChange(of: sceneFocusEnabled, initial: false) { _, newValue in
        if newValue {
          scheduleCanvasKeyboardFocusRestoreIfNeeded()
        } else {
          canvasKeyboardFocusedState = false
        }
      }
      .onChange(of: searchPaletteVisible, initial: false) { _, newValue in
        if !newValue {
          scheduleCanvasKeyboardFocusRestoreIfNeeded()
        }
      }
      .onChange(of: presentedEditSheet, initial: false) { _, newValue in
        if newValue == nil {
          scheduleCanvasKeyboardFocusRestoreIfNeeded()
        }
      }
      // `@Environment(\.undoManager)` is window-scoped and may flip when the
      // canvas is reparented (e.g. focus moves between session windows). Re-
      // attach on every change so subsequent `mutate(_:)` calls register
      // against the live manager. Reads inside `.onChange` see the new value.
      .onChange(of: undoManager) { _, newValue in
        viewModel.attachUndoManager(newValue)
      }
      // Re-bind when the user changes the autosave window in Settings so the
      // new interval (or Off) takes hold live, without reopening the canvas.
      .onChange(of: autosaveDebounceSeconds) { _, _ in
        bindAutosaveTrigger()
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

}
