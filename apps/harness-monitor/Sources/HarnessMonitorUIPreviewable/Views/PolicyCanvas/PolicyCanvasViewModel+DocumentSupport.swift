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

func policyCanvasLoadedGraph(
  from document: TaskBoardPolicyPipelineDocument,
  policyGroupTitle: String?
) -> PolicyCanvasLoadedGraph {
  let layoutLookup = PolicyCanvasDocumentLayoutLookup(layout: document.layout)
  var loadedNodes = document.nodes.map {
    policyCanvasNode($0, layoutLookup: layoutLookup)
  }
  // The canvas drops the document's own node groups: layout is driven purely by
  // the dataflow graph. Instead every node joins ONE shared implicit cluster
  // that wraps the whole policy in a single labelled container box. This is the
  // single load chokepoint (both applyDocument and applyPersistedDocument route
  // through it).
  //
  // A nil groupID makes the engine synthesize one singleton group per node,
  // which the parallel-band pass then spreads apart vertically (a tall, sparse
  // layout). One shared cluster instead packs every node into a single tight
  // layered block, and because the parallel-band pass only stacks when two
  // groups share a rank, a lone all-encompassing group leaves node placement
  // untouched while still rendering one container frame.
  let implicitClusterID = "__policy_canvas_ungrouped__"
  for index in loadedNodes.indices {
    loadedNodes[index].groupID = implicitClusterID
  }
  let nodeLookup = PolicyCanvasNodeLookup(nodes: loadedNodes)
  let mappedEdges = document.edges.compactMap { edge in
    policyCanvasEdge(edge, nodeLookup: nodeLookup, assignPreferredPortSides: false)
  }
  // The frame tracks the live node bounds; reflow and `reconcileGroupFrames()`
  // rebuild it as the engine moves nodes.
  let containerGroups: [PolicyCanvasGroup]
  if let frame = policyCanvasGroupFrame(containing: loadedNodes) {
    containerGroups = [
      PolicyCanvasGroup(
        id: implicitClusterID,
        title: policyCanvasResolvedContainerGroupTitle(policyGroupTitle),
        frame: frame,
        tone: .intake
      )
    ]
  } else {
    containerGroups = []
  }
  return PolicyCanvasLoadedGraph(
    nodes: loadedNodes,
    groups: containerGroups,
    mappedEdges: mappedEdges
  )
}

func policyCanvasPrewarmLabSampleLayouts(
  document: TaskBoardPolicyPipelineDocument,
  policyGroupTitle: String?,
  algorithmSelection: PolicyCanvasAlgorithmSelection
) {
  let graph = policyCanvasLoadedGraph(from: document, policyGroupTitle: policyGroupTitle)
  let initialLayout = policyCanvasCleanInitialLayout(
    nodes: graph.nodes,
    groups: graph.groups,
    edges: graph.mappedEdges,
    algorithmSelection: algorithmSelection
  )
  let initialNodeLookup = PolicyCanvasNodeLookup(nodes: initialLayout.nodes)
  let reflowEdges = policyCanvasFoldParallelBranches(graph.mappedEdges).map { edge in
    policyCanvasApplyingPreferredPortSides(
      edge,
      nodeLookup: initialNodeLookup
    )
  }
  _ = policyCanvasCleanInitialLayout(
    nodes: initialLayout.nodes,
    groups: initialLayout.groups,
    edges: reflowEdges,
    mode: .explicitReflow(preserveManualAnchors: false),
    algorithmSelection: algorithmSelection
  )
}

func policyCanvasResolvedContainerGroupTitle(_ policyGroupTitle: String?) -> String {
  let trimmed = policyGroupTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
  if let trimmed, !trimmed.isEmpty {
    return trimmed
  }
  return "Policy"
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
    policyCanvasLoadedGraph(from: document, policyGroupTitle: policyGroupTitle)
  }

  /// Title for the single container group. Uses the host-provided policy name
  /// when present, otherwise a neutral label so the box still reads as a policy.
  var policyCanvasContainerGroupTitle: String {
    policyCanvasResolvedContainerGroupTitle(policyGroupTitle)
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
