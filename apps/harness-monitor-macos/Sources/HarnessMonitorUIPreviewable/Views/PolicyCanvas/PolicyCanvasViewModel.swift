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
  var zoom: CGFloat
  var highlightedGroupID: String?
  var highlightedInput: PolicyCanvasPortEndpoint?
  var backingDocument: TaskBoardPolicyPipelineDocument?
  var latestSimulation: TaskBoardPolicyPipelineSimulationResult?
  var documentDirty: Bool
  var viewportDirty: Bool
  var hasRequestedInitialRemoteLoad: Bool
  var viewportCenteringGeneration: UInt64

  /// Observed flag the chrome reads to surface the "Remote changes available"
  /// affordance. Kept separate from the underlying `PolicyCanvasPendingUpdate`
  /// storage so the payload struct stays off the @Observable graph — only the
  /// presence bit drives view invalidation. Writes go through
  /// `setPendingUpdate(_:)` to keep this and `pendingDocumentUpdate` in sync.
  var hasPendingDocumentUpdate: Bool

  /// In-flight rubber-band edge preview while the user drags from an output
  /// port. The rubber-band layer reads this to render the Bézier curve from
  /// source port to cursor — cursor writes happen at gesture rate
  /// (~60-120Hz), so every observer that subscribes to this field pays an
  /// invalidation per frame.
  ///
  /// Today the rubber-band layer is the lone in-body reader and it MUST
  /// invalidate on cursor writes to redraw the curve, so the field stays
  /// `@Observable`-tracked (a presence-bit-only pattern like
  /// `pendingDocumentUpdate` / `hasPendingDocumentUpdate` would force the
  /// rubber-band layer to subscribe through a separate version counter and
  /// reach back into ignored storage, which is more machinery than the lone
  /// consumer warrants). Other views (status chrome, accessibility surfaces,
  /// menu enablement) must read the `hasPendingEdge` presence bit below
  /// instead — never `pendingEdgePreview != nil` from inside a `body`.
  ///
  /// All writes still flow through `beginPendingEdge`/`updatePendingEdgeCursor`/
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

  @ObservationIgnored var nextNodeNumber: Int
  @ObservationIgnored var loadedDocumentRevision: UInt64?
  @ObservationIgnored var centeredViewportGeneration: UInt64 = 0
  @ObservationIgnored private var nodeDragOrigins: [String: CGPoint] = [:]
  @ObservationIgnored var groupDragOrigins: [String: CGRect] = [:]
  @ObservationIgnored var groupNodeDragOrigins: [String: [String: CGPoint]] = [:]
  @ObservationIgnored var cleanEphemeralNodeIDs: Set<String> = []
  @ObservationIgnored var cleanEphemeralEdgeIDs: Set<String> = []
  /// Diagonal cursor that advances each time the user clicks a palette button.
  /// Kept off the @Observable graph because clicks read-then-write atomically
  /// and the placement helper is the only consumer. Reset on `load(...)`.
  @ObservationIgnored var nextPaletteDropAnchor: CGPoint =
    PolicyCanvasLayout.initialPaletteDropAnchor

  /// Severity-map cache for the validator hot path. `@ObservationIgnored` is
  /// load-bearing: if SwiftUI observed this slot, every body that reads
  /// `nodeSeverityMap` / `edgeSeverityMap` would re-run on cache write
  /// (which itself is triggered by the same body reading the map) and the
  /// cache would defeat itself. Writes go through `cachedSeverityMaps()`.
  @ObservationIgnored var validationCacheStorage: PolicyCanvasValidationCacheEntry?

  /// Bumped by `invalidateValidationCache()` from every mutation site that
  /// can change validator output without touching the count-style token
  /// fields (drag end, position adjustment, group reflow). Folded into
  /// `ValidationCacheToken` so a drag-only frame still invalidates the
  /// cached maps.
  @ObservationIgnored var validationInvalidationGeneration: UInt64 = 0

  init(
    selectedTab: PolicyCanvasTab = .draft,
    nodes: [PolicyCanvasNode],
    groups: [PolicyCanvasGroup],
    edges: [PolicyCanvasEdge],
    selection: PolicyCanvasSelection? = nil,
    zoom: CGFloat = 0.92,
    nextNodeNumber: Int = 10
  ) {
    self.selectedTab = selectedTab
    self.nodes = nodes
    self.groups = groups
    self.edges = edges
    self.selection = selection
    self.zoom = zoom
    self.backingDocument = nil
    self.latestSimulation = nil
    self.documentDirty = false
    self.viewportDirty = false
    self.hasRequestedInitialRemoteLoad = false
    self.viewportCenteringGeneration = 0
    self.hasPendingDocumentUpdate = false
    self.pendingDocumentUpdate = nil
    self.pendingEdgePreview = nil
    self.hasPendingEdge = false
    self.nextNodeNumber = nextNodeNumber
    reconcileGroupFrames()
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

  func dropPalettePayloads(_ payloads: [String], at point: CGPoint) -> Bool {
    guard
      let payload = payloads.first,
      let kind = parsePalettePayload(payload)
    else {
      return false
    }
    createNode(kind: kind, at: point)
    return true
  }

  func createNode(kind: PolicyCanvasNodeKind, at point: CGPoint) {
    let number = nextNodeNumber
    nextNodeNumber += 1
    var node = PolicyCanvasNode(
      id: "\(kind.rawValue)-\(number)",
      title: "\(kind.title) \(number)",
      kind: kind,
      position: snapped(
        CGPoint(
          x: point.x - PolicyCanvasLayout.nodeSize.width / 2,
          y: point.y - PolicyCanvasLayout.nodeSize.height / 2
        )
      )
    )
    node.groupID = containingGroupID(for: nodeCenter(node))
    node.policyKind = taskBoardPolicyNodeKind(for: kind)
    nodes.append(node)
    cleanEphemeralNodeIDs.insert(node.id)
    reconcileGroupFrames()
    selection = .node(node.id)
    documentDirty = true
    invalidateValidationCache()
    notifyStatus("\(kind.title) node added")
  }

  func dragNode(_ nodeID: String, translation: CGSize) {
    guard let index = nodes.firstIndex(where: { $0.id == nodeID }) else {
      return
    }
    if nodeDragOrigins[nodeID] == nil {
      nodeDragOrigins[nodeID] = nodes[index].position
    }
    markNodeEdited(nodeID)
    let origin = nodeDragOrigins[nodeID] ?? nodes[index].position
    nodes[index].position = snapped(
      CGPoint(
        x: origin.x + translation.width / zoom,
        y: origin.y + translation.height / zoom
      )
    )
    highlightedGroupID =
      containingGroupID(for: nodeCenter(nodes[index]), excluding: nodes[index].groupID)
      ?? nodes[index].groupID
    reconcileGroupFrames()
    selection = .node(nodeID)
    documentDirty = true
  }

  func endNodeDrag(_ nodeID: String, translation: CGSize) {
    dragNode(nodeID, translation: translation)
    if let index = nodes.firstIndex(where: { $0.id == nodeID }) {
      let targetGroupID = containingGroupID(
        for: nodeCenter(nodes[index]),
        excluding: nodes[index].groupID
      )
      if let targetGroupID {
        nodes[index].groupID = targetGroupID
      } else if nodes[index].groupID == nil {
        nodes[index].groupID = containingGroupID(for: nodeCenter(nodes[index]))
      }
    }
    reconcileGroupFrames()
    nodeDragOrigins[nodeID] = nil
    highlightedGroupID = nil
    // Drag-only mutation: token count fields don't change, but orphan
    // grouping changes can flip the validator. Bump generation here, not
    // in `dragNode` — pinging the cache 60 times during a drag would
    // shadow the very rebuild we're trying to avoid.
    invalidateValidationCache()
  }

  func dragGroup(_ groupID: String, translation: CGSize) {
    guard let index = groups.firstIndex(where: { $0.id == groupID }) else {
      return
    }
    seedGroupDrag(groupID: groupID, group: groups[index])
    let origin = groupDragOrigins[groupID] ?? groups[index].frame
    let nextOrigin = snapped(
      CGPoint(
        x: origin.origin.x + translation.width / zoom,
        y: origin.origin.y + translation.height / zoom
      )
    )
    let delta = CGSize(
      width: nextOrigin.x - origin.origin.x,
      height: nextOrigin.y - origin.origin.y
    )
    groups[index].frame.origin = nextOrigin
    moveNodes(in: groupID, by: delta)
    reconcileGroupFrames()
    highlightedGroupID = groupID
    selection = .group(groupID)
    documentDirty = true
  }

  func endGroupDrag(_ groupID: String, translation: CGSize) {
    dragGroup(groupID, translation: translation)
    groupDragOrigins[groupID] = nil
    groupNodeDragOrigins[groupID] = nil
    highlightedGroupID = nil
    // Group drag moves nodes inside the group; same rationale as
    // `endNodeDrag` — bump on the end-of-gesture, not every tick.
    invalidateValidationCache()
  }

  func setInputTargeted(
    _ targeted: Bool,
    nodeID: String,
    portID: String,
    side: PolicyCanvasPortSide? = nil
  ) {
    if targeted {
      highlightedInput = PolicyCanvasPortEndpoint(
        nodeID: nodeID,
        portID: portID,
        kind: .input,
        side: side
      )
    } else {
      highlightedInput = nil
    }
  }

  func connectDroppedPortPayloads(
    _ payloads: [String],
    targetNodeID: String,
    targetPortID: String,
    targetSide: PolicyCanvasPortSide? = nil
  ) -> Bool {
    guard let source = payloads.compactMap(parseOutputPortPayload).first else {
      clearPendingEdge()
      return false
    }
    guard source.nodeID != targetNodeID else {
      clearPendingEdge()
      return false
    }
    let target = PolicyCanvasPortEndpoint(
      nodeID: targetNodeID,
      portID: targetPortID,
      kind: .input,
      side: targetSide
    )
    guard !edges.contains(where: { $0.source == source && $0.target == target }) else {
      clearPendingEdge()
      return true
    }
    let edge = PolicyCanvasEdge(
      id: "edge-\(source.nodeID)-\(source.portID)-\(target.nodeID)-\(target.portID)",
      source: source,
      target: target,
      label: edgeLabel(source: source, target: target)
    )
    edges.append(edge)
    cleanEphemeralEdgeIDs.insert(edge.id)
    selection = .edge(edge.id)
    clearPendingEdge()
    documentDirty = true
    invalidateValidationCache()
    notifyStatus("Edge created")
    return true
  }

  private func parsePalettePayload(_ payload: String) -> PolicyCanvasNodeKind? {
    let parts = payload.split(separator: "|").map(String.init)
    guard parts.count == 2, parts[0] == "policy-canvas-palette" else {
      return nil
    }
    return PolicyCanvasNodeKind(rawValue: parts[1])
  }

  private func parseOutputPortPayload(_ payload: String) -> PolicyCanvasPortEndpoint? {
    let parts = payload.split(separator: "|").map(String.init)
    guard (parts.count == 3 || parts.count == 4), parts[0] == "policy-canvas-port" else {
      return nil
    }
    let side = parts.count == 4 ? PolicyCanvasPortSide(rawValue: parts[3]) : nil
    return PolicyCanvasPortEndpoint(
      nodeID: parts[1],
      portID: parts[2],
      kind: .output,
      side: side
    )
  }

  private func edgeLabel(
    source: PolicyCanvasPortEndpoint,
    target: PolicyCanvasPortEndpoint
  ) -> String {
    let sourcePort = node(source.nodeID)?.outputPorts.first { $0.id == source.portID }
    let targetPort = node(target.nodeID)?.inputPorts.first { $0.id == target.portID }
    return [sourcePort?.title, targetPort?.title]
      .compactMap { $0 }
      .joined(separator: " -> ")
  }

  func markNodeEdited(_ nodeID: String) {
    cleanEphemeralNodeIDs.remove(nodeID)
  }

  func markEdgeEdited(_ edgeID: String) {
    cleanEphemeralEdgeIDs.remove(edgeID)
  }

  func resetCleanEphemeralComponents() {
    cleanEphemeralNodeIDs.removeAll()
    cleanEphemeralEdgeIDs.removeAll()
  }

}
