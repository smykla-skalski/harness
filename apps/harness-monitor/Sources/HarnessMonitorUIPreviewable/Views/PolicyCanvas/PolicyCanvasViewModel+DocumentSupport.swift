import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms

/// Snapshot of a dashboard-side policy pipeline update deferred while the user
/// has unsaved local edits. Held by `PolicyCanvasViewModel` until the caller
/// invokes `applyPendingUpdate()` (typically after a user-driven "reload"
/// affordance in the canvas chrome).
struct PolicyCanvasPendingUpdate: Equatable {
  let document: TaskBoardPolicyPipelineDocument?
  let simulation: TaskBoardPolicyPipelineSimulationResult?
  let audit: TaskBoardPolicyPipelineAuditSummary?
  let activeCanvasId: String?
}

struct PolicyCanvasLoadedGraph {
  let nodes: [PolicyCanvasNode]
  let groups: [PolicyCanvasGroup]
  let mappedEdges: [PolicyCanvasEdge]
}

extension PolicyCanvasViewModel {
  /// Apply any pending dashboard update, overwriting local edits. The
  /// underlying persisted-document path clears `documentDirty` and the pending
  /// storage itself on the clean path, so this method does no pre-apply state
  /// writes — pre-clearing would leave state "clean but stale" if
  /// the document adoption ever short-circuits mid-execution.
  func applyPendingUpdate() {
    guard let pending = pendingDocumentUpdate else {
      return
    }
    applyPersistedDocument(
      document: pending.document,
      simulation: pending.simulation,
      audit: pending.audit,
      activeCanvasId: pending.activeCanvasId
    )
  }

  /// Stable identifier for the currently loaded canvas, or nil before any
  /// document is loaded. Multi-canvas routes prefer the daemon-owned canvas
  /// id; preview/lab routes that do not carry one fall back to the first
  /// policy trace id.
  var pipelineIdentity: String? {
    activeCanvasId ?? backingDocument?.policyTraceIds.first
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
    return !incomingDocumentMatchesBacking(document)
  }

  func markLoadedDocumentRevision(_ revision: UInt64?) {
    loadedDocumentRevision = revision
  }

  func policyCanvasGraph(
    from document: TaskBoardPolicyPipelineDocument
  ) -> PolicyCanvasLoadedGraph {
    var loadedNodes = document.nodes.map {
      policyCanvasNode($0, layout: document.layout)
    }
    // The canvas drops groups: the layout is driven purely by the dataflow graph
    // and no group boxes are drawn. This is the single load chokepoint (both
    // applyDocument and applyPersistedDocument route through it).
    //
    // Assign every node to ONE shared implicit cluster rather than clearing the
    // membership. A nil groupID makes the engine synthesize one singleton group
    // per node, which the parallel-band pass then spreads apart vertically (a
    // tall, sparse layout). One shared cluster instead packs all nodes into a
    // single tight layered block. The cluster id matches no entry in the (empty)
    // group list, so it stays an internal layout-only group with no actual
    // group - nothing reaches `viewModel.groups`, so no box is ever rendered.
    let implicitClusterID = "__policy_canvas_ungrouped__"
    for index in loadedNodes.indices {
      loadedNodes[index].groupID = implicitClusterID
    }
    let mappedEdges = document.edges.compactMap { edge in
      policyCanvasEdge(edge, nodes: loadedNodes, assignPreferredPortSides: false)
    }
    return PolicyCanvasLoadedGraph(
      nodes: loadedNodes,
      groups: [],
      mappedEdges: mappedEdges
    )
  }

  func incomingDocumentMatchesBacking(_ document: TaskBoardPolicyPipelineDocument) -> Bool {
    guard let backing = backingDocument else {
      return false
    }
    guard backing.revision == document.revision, backing.mode == document.mode else {
      return false
    }
    return backing == document
  }

  /// True when `document.revision` is strictly greater than every revision this
  /// canvas already knows about — the one it loaded from and the highest it has
  /// itself persisted. Only such a document reflects a change made by another
  /// writer; a same-revision republish or the echo of our own save is not a
  /// remote change. Unknown revisions read as 0 so the first genuine bump still
  /// surfaces.
  func incomingDocumentIsNewerRemoteRevision(
    _ document: TaskBoardPolicyPipelineDocument
  ) -> Bool {
    document.revision > max(loadedDocumentRevision ?? 0, lastSelfSavedRevision ?? 0)
  }

  /// Refresh only the attached simulation/audit slots, leaving nodes, groups,
  /// edges, and the dirty flag untouched. Used by `load()` when a same-or-older
  /// revision arrives while the document is dirty so local edits survive the
  /// republish.
  func absorbExternalSimulationAudit(
    simulation: TaskBoardPolicyPipelineSimulationResult?,
    audit: TaskBoardPolicyPipelineAuditSummary?
  ) {
    if let incoming = simulation ?? audit?.latestSimulation {
      latestSimulation = incoming
      invalidateValidationCache()
    }
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
