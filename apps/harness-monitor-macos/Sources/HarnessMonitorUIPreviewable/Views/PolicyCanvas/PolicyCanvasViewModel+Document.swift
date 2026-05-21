import HarnessMonitorKit
import SwiftUI

/// Snapshot of a dashboard-side policy pipeline update deferred while the user
/// has unsaved local edits. Held by `PolicyCanvasViewModel` until the caller
/// invokes `applyPendingUpdate()` (typically after a user-driven "reload"
/// affordance in the canvas chrome).
struct PolicyCanvasPendingUpdate: Equatable {
  let document: TaskBoardPolicyPipelineDocument?
  let simulation: TaskBoardPolicyPipelineSimulationResult?
  let audit: TaskBoardPolicyPipelineAuditSummary?
}

extension PolicyCanvasViewModel {
  func load(
    document: TaskBoardPolicyPipelineDocument?,
    simulation: TaskBoardPolicyPipelineSimulationResult?,
    audit: TaskBoardPolicyPipelineAuditSummary?
  ) {
    // Three incoming shapes hit this seam; the dirty-gate branch handles one,
    // the rest fall through to applyDocument:
    //
    //   1. Different-revision document + documentDirty=true → stage as
    //      pendingDocumentUpdate, return early (this branch).
    //   2. Same-revision document (with or without dirty) → fall through;
    //      applyDocument short-circuits inside before rewriting nodes/groups/
    //      edges, only updating latestSimulation. Local edits survive.
    //   3. Nil document (audit-only / simulation-only) → fall through;
    //      applyDocument's `guard let document` updates latestSimulation and
    //      returns. Local edits survive.
    //
    // Compare revision (UInt64) rather than the full document — the daemon
    // increments it on every persisted change, so a one-cycle compare replaces
    // a deep walk over nodes/edges/groups/actions/checks on every dashboard
    // publish.
    let incomingDiffers = document != nil && document?.revision != backingDocument?.revision
    if documentDirty && incomingDiffers {
      setPendingUpdate(
        PolicyCanvasPendingUpdate(
          document: document,
          simulation: simulation,
          audit: audit
        )
      )
      return
    }
    applyDocument(document: document, simulation: simulation, audit: audit)
  }

  /// Applies a dashboard payload unconditionally, bypassing the dirty-protect
  /// gate in `load()`. Used by `applyPendingUpdate()` to commit a previously
  /// staged update; same code path otherwise produces a "clean and stale"
  /// state if a manual `documentDirty = false` were paired with a separate
  /// `load(...)` call that early-returns mid-flight.
  func applyDocument(
    document: TaskBoardPolicyPipelineDocument?,
    simulation: TaskBoardPolicyPipelineSimulationResult?,
    audit: TaskBoardPolicyPipelineAuditSummary?
  ) {
    // On document-preserving paths (nil incoming doc, same-revision republish)
    // only overwrite latestSimulation when the incoming payload actually
    // carries one. A nil-republish must not nil out a sim that still matches
    // the current revision — otherwise promoteDisabledReason flips back to
    // "Run simulation first" after a harmless audit-only push.
    guard let document else {
      if let incoming = simulation ?? audit?.latestSimulation {
        latestSimulation = incoming
        invalidateValidationCache()
      }
      return
    }
    // Same-revision republish: the daemon emitted no document change, only
    // simulation/audit. Keep local nodes/groups/edges as-is and update the
    // attached sim/audit slots silently.
    //
    // Transient gesture state (rubber-band preview, port/group highlights,
    // palette drop cursor) is anchored to specific nodes/ports that, while
    // node identity is preserved by this branch, may move once layout
    // reconciles around an audit-driven republish. Clearing here keeps the
    // affordances honest: a rubber-band drag that started before the
    // republish drops on the next gesture, not on a stale anchor.
    if let backing = backingDocument, backing.revision == document.revision {
      if let incoming = simulation ?? audit?.latestSimulation {
        latestSimulation = incoming
        invalidateValidationCache()
      }
      clearTransientGestureState()
      resetPaletteDropPlacement()
      return
    }
    backingDocument = document
    secondarySelections = []
    latestSimulation = simulation ?? audit?.latestSimulation
    var loadedNodes = document.nodes.map {
      policyCanvasNode($0, layout: document.layout)
    }
    assignGroupMembership(from: document.groups, to: &loadedNodes)
    let loadedGroups = document.groups.enumerated().map { offset, group in
      policyCanvasGroup(offset: offset, element: group, nodes: loadedNodes)
    }
    let cleanLayout = policyCanvasCleanInitialLayout(nodes: loadedNodes, groups: loadedGroups)
    nodes = cleanLayout.nodes
    groups = cleanLayout.groups
    edges = document.edges.compactMap { edge in
      policyCanvasEdge(edge, nodes: cleanLayout.nodes)
    }
    zoom = Self.sanitizedZoom(CGFloat(document.layout.zoom), fallback: 1)
    reconcileGroupFrames()
    resetNextNodeNumber()
    markLoadedDocumentRevision(document.revision)
    resetCleanEphemeralComponents()
    resetPaletteDropPlacement()
    clearTransientGestureState()
    documentDirty = false
    viewportDirty = false
    setPendingUpdate(nil)
    invalidateValidationCache()
    requestViewportCentering()
    // Cross-revision load replaces the editable graph wholesale. The undo
    // stack from the previous revision references node/group/edge ids that
    // may no longer exist; replaying an inverse against the freshly loaded
    // graph would either crash on missing ids or restore stale state.
    clearUndoStack()
    notifyStatus("Loaded revision \(document.revision)")
  }

  func loadIfChanged(
    document: TaskBoardPolicyPipelineDocument?,
    simulation: TaskBoardPolicyPipelineSimulationResult?,
    audit: TaskBoardPolicyPipelineAuditSummary?,
    force: Bool = false
  ) {
    guard force || shouldApplyExternalDocument(document) else {
      latestSimulation = simulation ?? audit?.latestSimulation
      return
    }
    load(document: document, simulation: simulation, audit: audit)
  }

  /// Capture the editable graph (nodes, groups, edges, selection, latest
  /// simulation) into a value-typed snapshot. Callers stash the result before
  /// any daemon round-trip that might reject the export, then call
  /// `restoreState(_:)` on rejection so in-memory state never silently diverges
  /// from the saved `backingDocument`. The snapshot intentionally omits
  /// viewport-side state (zoom, `viewportDirty`) and document-side dirty flags
  /// — see `PolicyCanvasSnapshot` for the membership contract.
  ///
  /// Side effect: clears `highlightedInput` / `highlightedGroupID` so a port or
  /// group drag that was in flight when the round-trip starts does not leave
  /// stale tints lit across the daemon await. Transient gesture state is
  /// view-local and never part of the saved pipeline, so dropping it here
  /// matches the round-trip boundary semantics.
  func snapshotState() -> PolicyCanvasSnapshot {
    clearTransientGestureState()
    return PolicyCanvasSnapshot(
      nodes: nodes,
      groups: groups,
      edges: edges,
      selection: selection,
      latestSimulation: latestSimulation
    )
  }

  /// Replace the editable graph with a previously captured snapshot. Used by
  /// save/simulate/promote rejection paths to roll local state back to the
  /// pre-attempt graph. The default `markDirty: true` keeps the rejection-path
  /// contract: a follow-up retry will still consider the local copy dirty so
  /// the user can resave; clearing dirty there would leave the view in a
  /// "clean but unsynced" state if the daemon rejects the same payload again.
  /// Pass `markDirty: false` for "discard local edits" flows where the caller
  /// has separately validated that the restored snapshot matches what the
  /// daemon believes is the truth.
  ///
  /// The `reason` parameter funnels the human-readable status string through a
  /// single notify call, so callers do not need to second-write `statusLine`
  /// afterward — the second write wins by ordering luck and creates a
  /// distinct-message-per-event mismatch (save reject vs. simulate reject).
  func restoreState(
    _ snapshot: PolicyCanvasSnapshot,
    markDirty: Bool = true,
    reason: String = "Save rejected, restored previous canvas"
  ) {
    nodes = snapshot.nodes
    groups = snapshot.groups
    edges = snapshot.edges
    selection = snapshot.selection
    secondarySelections = []
    latestSimulation = snapshot.latestSimulation
    reconcileGroupFrames()
    // Write `documentDirty` directly (NOT through `markDocumentDirty`) and
    // pre-arm the one-shot suppression so the autosave loop does not fire
    // on the rollback's dirty flip. Without this guard, a daemon reject
    // would auto-retry the same rejected payload every debounce window.
    if markDirty {
      autosaveSuppressed = true
    }
    documentDirty = markDirty
    clearTransientGestureState()
    resetPaletteDropPlacement()
    invalidateValidationCache()
    // A rejected daemon round-trip is not a replayable user action — drop
    // the undo stack so Cmd-Z doesn't replay the rejected payload (or
    // worse, undo the rollback and re-arm the next autosave to fire the
    // rejected payload back at the daemon). Foreign actions (text-field
    // undo from outside the canvas) survive because `clearUndoStack`
    // removes only target-keyed actions; the runloop tick that follows
    // closes any in-flight event group automatically.
    clearUndoStack()
    notifyStatus(reason)
  }

  func exportDocument() -> TaskBoardPolicyPipelineDocument {
    reconcileGroupFrames()
    let originalNodeKinds =
      backingDocument.map { document in
        Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, $0.kind) })
      } ?? [:]
    let originalEdgeConditions =
      backingDocument.map { document in
        Dictionary(uniqueKeysWithValues: document.edges.map { ($0.id, $0.condition) })
      } ?? [:]
    let liveNodeIDs = Set(nodes.map(\.id))
    return TaskBoardPolicyPipelineDocument(
      schemaVersion: backingDocument?.schemaVersion ?? 2,
      revision: backingDocument?.revision ?? 1,
      mode: .draft,
      nodes: nodes.map { node in
        taskBoardPolicyNode(node, originalKind: originalNodeKinds[node.id])
      },
      edges: edges.compactMap { edge in
        guard liveNodeIDs.contains(edge.source.nodeID),
          liveNodeIDs.contains(edge.target.nodeID)
        else { return nil }
        return taskBoardPolicyEdge(edge, originalCondition: originalEdgeConditions[edge.id])
      },
      groups: groups.map { group in
        taskBoardPolicyGroup(group, nodes: nodes)
      },
      layout: TaskBoardPolicyPipelineLayout(
        zoom: Double(zoom),
        offset: backingDocument?.layout.offset ?? .zero,
        nodes: nodes.map(taskBoardPolicyNodeLayout)
      ),
      policyTraceIds: backingDocument?.policyTraceIds ?? []
    )
  }

  /// Apply any pending dashboard update, overwriting local edits. The
  /// underlying `applyDocument(...)` clears `documentDirty` and the pending
  /// storage itself on the clean path, so this method does no pre-apply state
  /// writes — pre-clearing would leave state "clean but stale" if
  /// `applyDocument` ever short-circuits mid-execution.
  func applyPendingUpdate() {
    guard let pending = pendingDocumentUpdate else {
      return
    }
    applyDocument(
      document: pending.document,
      simulation: pending.simulation,
      audit: pending.audit
    )
  }

  /// Stable identifier for the currently loaded pipeline, or nil before any
  /// document is loaded. Today the daemon does not carry a dedicated pipeline
  /// id, so we derive one from the first policy trace id (stable across saves
  /// of the same pipeline). View identity changes only when the underlying
  /// pipeline switches, not on every revision bump.
  ///
  /// Returning nil instead of a sentinel "default" prevents two distinct
  /// trace-less pipelines from sharing the same `.id()` — callers must skip
  /// the `.id()` modifier entirely when this is nil. The host view does so
  /// via `optionalID(_:)` in `PolicyCanvasView`.
  var pipelineIdentity: String? {
    backingDocument?.policyTraceIds.first
  }

  /// Single writer that keeps the @ObservationIgnored `pendingDocumentUpdate`
  /// storage and the observed `hasPendingDocumentUpdate` flag in sync. Internal
  /// callers must always go through this — direct writes to
  /// `pendingDocumentUpdate` would leave the chrome's "Remote changes
  /// available" affordance stuck on its previous value.
  func setPendingUpdate(_ value: PolicyCanvasPendingUpdate?) {
    pendingDocumentUpdate = value
    hasPendingDocumentUpdate = value != nil
  }

  func resetNextNodeNumber() {
    nextNodeNumber = nodes.count + 1
  }

  func markInitialRemoteLoadRequested() -> Bool {
    guard !hasRequestedInitialRemoteLoad else {
      return false
    }
    hasRequestedInitialRemoteLoad = true
    return true
  }

  func shouldApplyExternalDocument(_ document: TaskBoardPolicyPipelineDocument?) -> Bool {
    guard let document else {
      return false
    }
    guard !documentDirty else {
      return false
    }
    return loadedDocumentRevision != document.revision || backingDocument?.mode != document.mode
  }

  func markLoadedDocumentRevision(_ revision: UInt64?) {
    loadedDocumentRevision = revision
  }

  private func assignGroupMembership(
    from groups: [TaskBoardPolicyPipelineGroup],
    to nodes: inout [PolicyCanvasNode]
  ) {
    for group in groups {
      for nodeID in group.nodeIds {
        guard let index = nodes.firstIndex(where: { $0.id == nodeID }) else {
          continue
        }
        nodes[index].groupID = nodes[index].groupID ?? group.id
      }
    }
  }
}
