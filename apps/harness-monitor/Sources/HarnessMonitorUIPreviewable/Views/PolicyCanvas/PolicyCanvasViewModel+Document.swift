import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

extension PolicyCanvasViewModel {
  func load(
    document: TaskBoardPolicyPipelineDocument?,
    simulation: TaskBoardPolicyPipelineSimulationResult?,
    audit: TaskBoardPolicyPipelineAuditSummary?,
    activeCanvasId: String? = nil
  ) {
    // While the user has unsaved edits, an incoming daemon document is a remote
    // change worth surfacing only when its revision is strictly newer than the
    // one we are editing from (and newer than any revision we just saved
    // ourselves). Same-revision re-serializations and the echo of our own save
    // are NOT remote changes: treating them as such raised a spurious "Remote
    // changes available" banner on every republish and stranded the in-progress
    // edit behind a reload prompt. A nil document (audit/simulation-only push)
    // and the not-dirty path both fall through to applyDocument, which already
    // preserves local edits on its same-document and nil-document branches.
    if documentDirty, let document {
      if incomingDocumentIsNewerRemoteRevision(document) {
        setPendingUpdate(
          PolicyCanvasPendingUpdate(
            document: document,
            simulation: simulation,
            audit: audit,
            activeCanvasId: activeCanvasId
          )
        )
        return
      }
      // Same-or-older revision while dirty: keep local edits untouched and only
      // refresh the attached simulation/audit, mirroring applyDocument's
      // exact-republish branch without rebuilding the graph.
      absorbExternalSimulationAudit(simulation: simulation, audit: audit)
      return
    }
    applyDocument(
      document: document,
      simulation: simulation,
      audit: audit,
      activeCanvasId: activeCanvasId
    )
  }

  /// Applies a dashboard payload unconditionally, bypassing the dirty-protect
  /// gate in `load()`. Used by `applyPendingUpdate()` to commit a previously
  /// staged update; same code path otherwise produces a "clean and stale"
  /// state if a manual `documentDirty = false` were paired with a separate
  /// `load(...)` call that early-returns mid-flight.
  public func applyDocument(
    document: TaskBoardPolicyPipelineDocument?,
    simulation: TaskBoardPolicyPipelineSimulationResult?,
    audit: TaskBoardPolicyPipelineAuditSummary?,
    activeCanvasId: String? = nil,
    forceDocumentReload: Bool = false
  ) {
    self.activeCanvasId = activeCanvasId
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
    // Exact-document republish: the daemon emitted no document change, only
    // simulation/audit. Keep local nodes/groups/edges as-is and update the
    // attached sim/audit slots silently.
    //
    // Transient gesture state (rubber-band preview, port/group highlights,
    // palette drop cursor) is anchored to specific nodes/ports that, while
    // node identity is preserved by this branch, may move once layout
    // reconciles around an audit-driven republish. Clearing here keeps the
    // affordances honest: a rubber-band drag that started before the
    // republish drops on the next gesture, not on a stale anchor.
    if !forceDocumentReload && incomingDocumentMatchesBacking(document) {
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
    let graph = policyCanvasGraph(from: document)
    // Fold convergent same-endpoint families into one merged wire so the whole
    // routing/marker/selection pipeline treats a fan-in as a single edge.
    let foldedEdges = policyCanvasFoldParallelBranches(graph.mappedEdges)
    // Layout runs on the UNFOLDED edges: the auto-arrange engine is sensitive to
    // edge multiplicity, so feeding it the folded set would silently reshape node
    // positions graph-wide (and push unrelated terminal edges into bug-2 jogs).
    // Node positions reflect connectivity, which folding parallel edges never
    // changes - so layout stays identical whether a family is folded or not.
    let cleanLayout = policyCanvasCleanInitialLayout(
      nodes: graph.nodes,
      groups: graph.groups,
      edges: graph.mappedEdges,
      algorithmSelection: algorithmSelection
    )
    nodes = cleanLayout.nodes
    groups = cleanLayout.groups
    edges = foldedEdges.map { edge in
      policyCanvasApplyingPreferredPortSides(edge, nodes: cleanLayout.nodes)
    }
    routingHints =
      policyCanvasRoutingHintsForCurrentLayout(nodes: nodes, groups: groups, edges: edges)
      ?? cleanLayout.routingHints
    zoom = Self.sanitizedZoom(CGFloat(document.layout.zoom), fallback: 1)
    reconcileGroupFrames()
    resetNextNodeNumber()
    markLoadedDocumentRevision(document.revision)
    documentGeneration = 0
    resetCleanEphemeralComponents()
    resetPaletteDropPlacement()
    clearTransientGestureState()
    documentDirty = false
    viewportDirty = false
    setPendingUpdate(nil)
    invalidateValidationCache()
    requestViewportCentering(.document)
    // Cross-revision load replaces the editable graph wholesale. The undo
    // stack from the previous revision references node/group/edge ids that
    // may no longer exist; replaying an inverse against the freshly loaded
    // graph would either crash on missing ids or restore stale state.
    clearUndoStack()
    notifyStatus("Loaded revision \(document.revision)")
  }

  public func applyPersistedDocument(
    document: TaskBoardPolicyPipelineDocument?,
    simulation: TaskBoardPolicyPipelineSimulationResult?,
    audit: TaskBoardPolicyPipelineAuditSummary?,
    activeCanvasId: String?
  ) {
    self.activeCanvasId = activeCanvasId
    guard let document else {
      if let incoming = simulation ?? audit?.latestSimulation {
        latestSimulation = incoming
        validationPresentation = .empty
        invalidateValidationCache()
      }
      return
    }
    if incomingDocumentMatchesBacking(document) {
      if let incoming = simulation ?? audit?.latestSimulation {
        latestSimulation = incoming
        validationPresentation = .empty
        invalidateValidationCache()
      }
      clearTransientGestureState()
      resetPaletteDropPlacement()
      return
    }
    let graph = policyCanvasGraph(from: document)
    backingDocument = document
    secondarySelections = []
    latestSimulation = simulation ?? audit?.latestSimulation
    nodes = policyCanvasAssignTrustedLayoutSources(graph.nodes)
    groups = graph.groups
    edges = policyCanvasFoldParallelBranches(graph.mappedEdges).map { edge in
      policyCanvasApplyingPreferredPortSides(edge, nodes: nodes)
    }
    routingHints = policyCanvasRoutingHintsForCurrentLayout(
      nodes: nodes, groups: groups, edges: edges)
    zoom = Self.sanitizedZoom(CGFloat(document.layout.zoom), fallback: 1)
    resetNextNodeNumber()
    markLoadedDocumentRevision(document.revision)
    documentGeneration = 0
    resetCleanEphemeralComponents()
    resetPaletteDropPlacement()
    clearTransientGestureState()
    documentDirty = false
    viewportDirty = false
    setPendingUpdate(nil)
    validationPresentation = .empty
    invalidateValidationCache()
    requestViewportCentering(.document)
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
    load(
      document: document,
      simulation: simulation,
      audit: audit,
      activeCanvasId: activeCanvasId
    )
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
      latestSimulation: latestSimulation,
      routingHints: routingHints
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
    routingHints = snapshot.routingHints
    reconcileGroupFrames()
    // Write `documentDirty` directly (NOT through `markDocumentDirty`) and
    // pre-arm the one-shot suppression so the autosave loop does not fire
    // on the rollback's dirty flip. Without this guard, a daemon reject
    // would auto-retry the same rejected payload every debounce window.
    if markDirty {
      autosaveSuppressed = true
      documentGeneration = documentGeneration &+ 1
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

  func documentExportPayload(
    from snapshot: PolicyCanvasSnapshot? = nil
  ) -> PolicyCanvasDocumentExportPayload {
    PolicyCanvasDocumentExportPayload(
      nodes: snapshot?.nodes ?? nodes,
      groups: snapshot?.groups ?? groups,
      edges: snapshot?.edges ?? edges,
      zoom: zoom,
      backingDocument: backingDocument
    )
  }

  public func exportDocument() -> TaskBoardPolicyPipelineDocument {
    reconcileGroupFrames()
    return documentExportPayload().exportDocument()
  }

  /// Compare the current graph to the saved backing off the main actor. Drag
  /// release uses this to keep the gesture path out of the full export walk.
  func reconcileDocumentDirtyWithBackingDocument() {
    guard let backingDocument else {
      return
    }
    let payload = documentExportPayload()
    let reconciliationGeneration = documentGeneration
    let backingRevision = backingDocument.revision
    HarnessMonitorAsyncWorkQueue.shared.submit(
      HarnessMonitorAsyncWorkQueue.WorkItem(title: "Reconciling policy canvas draft") {
        let isDirty = payload.exportDocument() != backingDocument
        await MainActor.run {
          guard self.documentGeneration == reconciliationGeneration,
            self.backingDocument?.revision == backingRevision
          else {
            return
          }
          self.documentDirty = isDirty
          if !isDirty {
            self.cancelAutosave()
            if self.saveActivity == .pending {
              self.enterSaveActivity(.idle)
            }
          }
        }
      }
    )
  }
}
