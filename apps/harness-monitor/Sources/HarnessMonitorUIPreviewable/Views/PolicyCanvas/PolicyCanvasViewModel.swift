import HarnessMonitorKit
import Observation
import SwiftUI

@MainActor
@Observable
final class PolicyCanvasViewModel {
  var selectedTab: PolicyCanvasTab
  var nodes: [PolicyCanvasNode]
  var groups: [PolicyCanvasGroup]
  var edges: [PolicyCanvasEdge]
  var selection: PolicyCanvasSelection?
  /// Additional shift-click selections layered on top of `selection`. The
  /// primary `selection` field stays the canonical "what is being edited" for
  /// inspector binding and selectionless-aware paths; `secondarySelections`
  /// only exists for power-edit operations (multi-delete, multi-copy,
  /// multi-nudge). Empty set means single-select behavior, which is the
  /// vast majority of the time and keeps the rest of the canvas untouched.
  var secondarySelections: Set<PolicyCanvasSelection>
  var zoom: CGFloat
  /// Unit-space pinch anchor; see `setZoom(_:anchor:)` in `+Commands.swift`.
  var pinchAnchorUnit: UnitPoint?
  var highlightedGroupID: String?
  /// Group id that just received a successful node drop. The workspace's
  /// group region reads this to render an "acceptance flash" — a brief
  /// opacity bump + accent stroke gating on `accessibilityReduceMotion`
  /// (Wave 4K P36). Auto-cleared after `groupAcceptanceFlashDuration` so the
  /// flash has a finite lifetime even if the view tree never observes a
  /// follow-up gesture. Reduce-motion clients skip the visual but still see
  /// the bit flip — VoiceOver announcements can hook into this signal in a
  /// later wave.
  var groupAcceptanceFlashID: String?
  var highlightedInput: PolicyCanvasPortEndpoint?
  var backingDocument: TaskBoardPolicyPipelineDocument?
  var latestSimulation: TaskBoardPolicyPipelineSimulationResult?
  var documentDirty: Bool
  var viewportDirty: Bool
  var hasRequestedInitialRemoteLoad: Bool
  var viewportCenteringGeneration: UInt64
  var routeComputationGeneration: UInt64
  var validationPresentation: PolicyCanvasValidationPresentation
  var cachedAutomationPolicyCompilation: PolicyCanvasAutomationPolicyCompilation

  /// Observed flag the chrome reads to surface the "Remote changes available"
  /// affordance. Kept separate from the underlying `PolicyCanvasPendingUpdate`
  /// storage so the payload struct stays off the @Observable graph — only the
  /// presence bit drives view invalidation. Writes go through
  /// `setPendingUpdate(_:)` to keep this and `pendingDocumentUpdate` in sync.
  var hasPendingDocumentUpdate: Bool

  /// In-flight rubber-band edge preview while the user drags from an output
  /// port. The rubber-band layer is the lone in-body reader and MUST
  /// invalidate on cursor writes (~60-120Hz) to redraw the curve, so the
  /// field stays `@Observable`-tracked. Every other reader (chrome, a11y,
  /// menu enablement) must subscribe through `hasPendingEdge` below.
  /// Writes flow through `beginPendingEdge` / `updatePendingEdgeCursor` /
  /// `clearPendingEdge`, which keep this and `hasPendingEdge` in sync.
  var pendingEdgePreview: PolicyCanvasPendingEdgePreview?

  /// Observed presence-bit mirror for `pendingEdgePreview`. Views that only
  /// need to know whether a rubber-band drag is in flight (chrome state,
  /// status surfaces, future tooltips) must subscribe through this flag to
  /// avoid invalidating per cursor frame. Maintained by the same writers as
  /// `pendingEdgePreview` so the two never drift.
  var hasPendingEdge: Bool

  /// Staged dashboard payload deferred while the user has unsaved local edits.
  /// `@ObservationIgnored` so updates here don't churn observers; write only
  /// via `setPendingUpdate(_:)` to keep the observed presence bit in sync.
  @ObservationIgnored var pendingDocumentUpdate: PolicyCanvasPendingUpdate?

  /// Notified whenever the view model emits a human-readable status update.
  /// Set by the host view, which mirrors the value into a `@State` line that
  /// the chrome reads. Kept off the @Observable storage so log strings do not
  /// pollute the document state graph or future undo register.
  @ObservationIgnored var statusCallback: (@MainActor (String) -> Void)?

  /// `@Environment(\.undoManager)` from the host view, bridged in via
  /// `attachUndoManager(_:)`. Held weakly so a window-close that tears down
  /// the environment does not keep a dead pointer alive. Read by the
  /// `mutate(_:)` funnel in `PolicyCanvasViewModel+UndoFunnel.swift`; direct
  /// access from other sites is forbidden — every undoable mutation must
  /// route through the funnel.
  @ObservationIgnored weak var undoManager: UndoManager?

  /// Fired by every mutation site that flips `documentDirty = true`. Set by
  /// the host view to schedule an autosave through `scheduleAutosave`. Kept
  /// off the @Observable graph so wiring it doesn't churn observers, and
  /// optional so unit-test paths (which never bind it) skip autosave
  /// entirely.
  @ObservationIgnored var autosaveTrigger: (@MainActor () -> Void)?

  /// In-memory clipboard captured by `copySelectionToClipboard()` and
  /// replayed by `pasteFromClipboard()`. Held off the @Observable graph
  /// because views never visualize the buffer itself; the only consumer is
  /// the paste command which reads it once per invocation.
  @ObservationIgnored var clipboard: PolicyCanvasClipboard?

  @ObservationIgnored var nextNodeNumber: Int
  @ObservationIgnored var loadedDocumentRevision: UInt64?
  @ObservationIgnored var centeredViewportGeneration: UInt64 = 0
  @ObservationIgnored var nodeDragOrigins: [String: CGPoint] = [:]
  @ObservationIgnored var groupDragOrigins: [String: CGRect] = [:]
  @ObservationIgnored var groupNodeDragOrigins: [String: [String: CGPoint]] = [:]
  @ObservationIgnored var cleanEphemeralNodeIDs: Set<String> = []
  @ObservationIgnored var cleanEphemeralEdgeIDs: Set<String> = []
  /// Diagonal cursor that advances each time the user clicks a palette button.
  /// Kept off the @Observable graph because clicks read-then-write atomically
  /// and the placement helper is the only consumer. Reset on `load(...)`.
  @ObservationIgnored var nextPaletteDropAnchor: CGPoint =
    PolicyCanvasLayout.initialPaletteDropAnchor

  /// Bumped by `invalidateValidationCache()` from every mutation site that
  /// can change validator output without touching the count-style token
  /// fields (drag end, position adjustment, group reflow). Folded into
  /// `ValidationCacheToken` so a drag-only frame still invalidates the
  /// cached maps.
  @ObservationIgnored var validationInvalidationGeneration: UInt64 = 0

  /// In-flight async-save state surfaced to the chrome so Save / Simulate /
  /// Promote buttons can flip into a busy presentation (disabled +
  /// `ProgressView`) without losing the toast-on-reject path. Reads from a
  /// view body redraw on flip, so writes must be paired with a corresponding
  /// false-write in `defer` blocks on every async exit.
  var isSavingDraft: Bool
  var isSimulating: Bool
  var isPromoting: Bool

  /// Coordinates autosave between the view-model and the host view. The
  /// host triggers `scheduleAutosave(performSave:)` after each documentDirty
  /// flip; the closure routes back to the same daemon save path as the
  /// foreground Save button so snapshot/restore + reload-on-success behave
  /// identically. `nonisolated(unsafe)` storage is not needed — the task is
  /// MainActor-bound and cancel is synchronous.
  @ObservationIgnored var autosaveTask: Task<Void, Never>?

  /// Set when `restoreState(_:)` is rolling local state back from a reject.
  /// Suppresses the next autosave trigger so the rollback's
  /// `documentDirty = true` write does not re-fire the daemon save that
  /// just failed; without this guard the autosave loop hammers the daemon
  /// every debounce window with a payload it already rejected.
  @ObservationIgnored var autosaveSuppressed: Bool

  /// Outcome of the most recent autosave attempt. Observed-tracked so the
  /// chrome can surface a "Autosave failed" status line when the daemon
  /// rejects an autosave; the user-facing notify funnel mirrors the same
  /// state into `statusLine`.
  var lastAutosaveOutcome: PolicyCanvasAutosaveOutcome

  /// Count of consecutive autosave failures since the last successful save.
  /// `@ObservationIgnored` because views subscribe through
  /// `lastAutosaveOutcome` (which flips to `.disabled` at the ceiling) — they
  /// do not need to invalidate on every increment. Cleared by
  /// `markAutosaveSucceeded()` and `clearAutosaveDecompensation()`.
  @ObservationIgnored var consecutiveAutosaveFailures: Int

  /// Maximum consecutive autosave rejects before the subsystem flips to
  /// `.disabled(reason:)`. Three is enough to ride out a brief daemon hiccup
  /// without burying the user under a stack of "Autosave rejected" toasts
  /// that each restore work they were still typing.
  static let autosaveFailureCeiling: Int = 3

  /// Acceptance-flash lifetime for the group drop affordance (Wave 4K P36).
  /// 600ms is the upper bound on a "this just happened" affordance — long
  /// enough for the user to register the visual confirmation, short enough
  /// to fade before the next gesture begins. The flash auto-clears after
  /// this interval via `triggerGroupAcceptanceFlash`.
  static let groupAcceptanceFlashDuration: Duration = .milliseconds(600)

  /// Auto-clear task armed by `triggerGroupAcceptanceFlash`. Kept off the
  /// @Observable graph because views read the flash via
  /// `groupAcceptanceFlashID`, not via task identity. Cancelled on every new
  /// flash so a rapid drop-drop sequence shows one continuous accent rather
  /// than overlapping fades.
  @ObservationIgnored var groupAcceptanceFlashTask: Task<Void, Never>?

  /// Snapshot of in-progress edits captured at the moment a daemon round-trip
  /// rejects. The chrome surfaces a "Recover" affordance the user can press
  /// to swap the rolled-back state back to the recovery snapshot — letting
  /// them keep edits they typed during the 200-2000ms round-trip window.
  /// `@ObservationIgnored` because the chrome only reads the presence bit
  /// `hasRecoverableEdits` to flip the affordance on; the snapshot payload
  /// itself is consumed lazily by `recoverRejectedEdits()`.
  @ObservationIgnored var lastRejectedRecovery: PolicyCanvasSnapshot?

  /// Observed presence-bit mirror for `lastRejectedRecovery`. Views that need
  /// to show the "Recover" affordance subscribe here instead of through the
  /// snapshot itself; flipping the bit is a single observer notification per
  /// reject (vs. per-field deep-equality on the snapshot payload).
  var hasRecoverableEdits: Bool

  /// Cache slot for the per-node simulation outcome map. `@ObservationIgnored`
  /// for the same reason as the validation worker's cached output: observed
  /// storage would make every body that reads the map invalidate on its own
  /// cache write.
  /// Token keyed on simulation revision + decisions count (see
  /// `SimulationOutcomeCacheToken`); writes flow through
  /// `simulationOutcomeMap()`.
  @ObservationIgnored var simulationOutcomeCacheStorage: PolicyCanvasSimulationOutcomeCacheEntry?

  init(
    selectedTab: PolicyCanvasTab = .draft,
    nodes: [PolicyCanvasNode],
    groups: [PolicyCanvasGroup],
    edges: [PolicyCanvasEdge],
    selection: PolicyCanvasSelection? = nil,
    zoom: CGFloat = PolicyCanvasLayout.defaultZoom,
    nextNodeNumber: Int = 10
  ) {
    self.selectedTab = selectedTab
    self.nodes = nodes
    self.groups = groups
    self.edges = edges
    self.selection = selection
    self.secondarySelections = []
    self.zoom = Self.sanitizedZoom(zoom, fallback: PolicyCanvasLayout.defaultZoom)
    self.pinchAnchorUnit = nil
    self.backingDocument = nil
    self.latestSimulation = nil
    self.documentDirty = false
    self.viewportDirty = false
    self.hasRequestedInitialRemoteLoad = false
    self.viewportCenteringGeneration = 0
    self.routeComputationGeneration = 0
    self.validationPresentation = .empty
    self.cachedAutomationPolicyCompilation = .empty
    self.hasPendingDocumentUpdate = false
    self.pendingDocumentUpdate = nil
    self.pendingEdgePreview = nil
    self.hasPendingEdge = false
    self.isSavingDraft = false
    self.isSimulating = false
    self.isPromoting = false
    self.autosaveSuppressed = false
    self.lastAutosaveOutcome = .idle
    self.consecutiveAutosaveFailures = 0
    self.lastRejectedRecovery = nil
    self.hasRecoverableEdits = false
    self.groupAcceptanceFlashID = nil
    self.nextNodeNumber = nextNodeNumber
    reconcileGroupFrames()
    refreshAutomationPolicyCompilation()
  }

  var selectedNode: PolicyCanvasNode? {
    guard case .node(let id) = selection else {
      return nil
    }
    return node(id)
  }

  var selectedGroup: PolicyCanvasGroup? {
    guard case .group(let id) = selection else {
      return nil
    }
    return group(id)
  }

  var selectedEdge: PolicyCanvasEdge? {
    guard case .edge(let id) = selection else {
      return nil
    }
    return edges.first { $0.id == id }
  }

  var selectedTitle: String {
    if let selectedNode {
      return selectedNode.title
    }
    if let selectedGroup {
      return selectedGroup.title
    }
    if let selectedEdge {
      return selectedEdge.label
    }
    return "Canvas"
  }

  var policySummary: String {
    "\(nodes.count) nodes - \(edges.count) edges - \(groups.count) groups"
  }

  var canPromote: Bool {
    promoteDisabledReason == nil
  }

  var promoteDisabledReason: String? {
    guard let backingDocument else {
      return "Save a draft first"
    }
    if documentDirty {
      return "Save draft changes first"
    }
    guard let latestSimulation else {
      return "Run simulation first"
    }
    guard latestSimulation.succeeded else {
      return "Fix validation before promotion"
    }
    guard latestSimulation.revision == backingDocument.revision else {
      return "Run simulation for saved revision"
    }
    return nil
  }

  /// Single funnel that mutation sites use to mark the document dirty. Sets
  /// `documentDirty = true` and fires the autosave trigger on the clean→dirty
  /// edge. Coalescing to the edge is load-bearing on drag paths: drag
  /// callbacks fire `markDocumentDirty()` per gesture tick (~60Hz), so a
  /// per-tick trigger would call `scheduleAutosave` 60 times per second and
  /// spawn-then-cancel a `Task` on every tick. Trailing-edge debounce already
  /// coalesces the actual saves, but the cancellation churn and `Task.isCancelled`
  /// checks add up; the edge gate drops them to a single trigger per dirty
  /// window. Subsequent `markDocumentDirty()` calls within the same dirty
  /// window flow into the already-scheduled debounce.
  func markDocumentDirty() {
    let wasClean = !documentDirty
    documentDirty = true
    if wasClean {
      autosaveTrigger?()
    }
  }

  func refreshAutomationPolicyCompilation() {
    let nextCompilation = PolicyCanvasAutomationPolicyCompiler.compile(nodes: nodes, edges: edges)
    guard cachedAutomationPolicyCompilation != nextCompilation else { return }
    cachedAutomationPolicyCompilation = nextCompilation
  }

}
