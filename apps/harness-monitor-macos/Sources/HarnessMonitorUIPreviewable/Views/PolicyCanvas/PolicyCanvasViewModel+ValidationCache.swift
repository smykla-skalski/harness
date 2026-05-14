import HarnessMonitorKit
import Observation

// SHIM: validation result caching is keyed on a coarse graph token that the
// view model bumps from every mutation site. Once the daemon emits structured
// per-node severity (see P11 shim notes in `+Validation.swift`), the entire
// `validateGraph()` path can go away and this cache reduces to passing daemon
// payloads straight through. Until then, this storage is the only thing
// keeping a drag gesture off the O(N) DFS hot path on every frame.

extension PolicyCanvasViewModel {
  /// Snapshot of the inputs the validator reads. Two reads with the same
  /// snapshot must produce the same `[String: PolicyCanvasIssueSeverity]`
  /// maps, so we use it as the cache key. Hashable on `(nodes.count,
  /// edges.count, groups.count, latestSimulation?.revision, validation
  /// issue count, validation isValid)` — coarse but cheap, and the
  /// `invalidateValidationCache()` callsites cover every shape-mutating
  /// path.
  struct ValidationCacheToken: Hashable {
    let nodeCount: Int
    let edgeCount: Int
    let groupCount: Int
    let simulationRevision: UInt64?
    let simulationIssueCount: Int
    let simulationValid: Bool
    /// Monotonic counter bumped by `invalidateValidationCache()`. Covers
    /// position-only mutations (node drags, group drags) that don't change
    /// any of the count fields but still need to invalidate cached
    /// severity maps when daemon issues reference moved nodes.
    let invalidationGeneration: UInt64
  }

  /// Returns the cache token for the current graph state. Reads through the
  /// observed `nodes`/`edges`/`groups`/`latestSimulation` storage; safe to
  /// call from a body, but should be paired with `cachedSeverityMaps()` so
  /// the per-body computation happens once instead of twice.
  func validationCacheToken() -> ValidationCacheToken {
    ValidationCacheToken(
      nodeCount: nodes.count,
      edgeCount: edges.count,
      groupCount: groups.count,
      simulationRevision: latestSimulation?.revision,
      simulationIssueCount: latestSimulation?.validation.issues.count ?? 0,
      simulationValid: latestSimulation?.validation.isValid ?? true,
      invalidationGeneration: validationInvalidationGeneration
    )
  }

  /// Mark the cached severity maps stale. Every mutation site that can
  /// change the validator's output must call this; we cover the obvious
  /// paths (node/edge/group add/remove, drag end, simulation install) in
  /// this file's mutation hooks and let `applyDocument` clear via the
  /// initializer-style reset in `+Document.swift`.
  ///
  /// Bumping a counter is cheaper than rebuilding the hashable token, and
  /// keeps the token contract local to `ValidationCacheToken` — callers
  /// outside this file just call `invalidateValidationCache()` and never
  /// touch the counter directly.
  func invalidateValidationCache() {
    validationInvalidationGeneration &+= 1
  }

  /// Read the cached severity maps, rebuilding them when the cache token
  /// no longer matches. The maps are returned together because every hot
  /// caller (node layer body, edge layer body, inspector issues section)
  /// reads both, and rebuilding both at once amortizes a single
  /// `allValidationIssues` walk over two outputs.
  ///
  /// Returned tuples are by value; callers must hoist into a body-local
  /// `let` so per-row `nodeSeverityMap[id]` reads stay O(1) and don't
  /// touch the cache token on every iteration.
  func cachedSeverityMaps() -> (
    nodes: [String: PolicyCanvasIssueSeverity],
    edges: [String: PolicyCanvasIssueSeverity]
  ) {
    let token = validationCacheToken()
    if let cached = validationCacheStorage, cached.token == token {
      return (cached.nodeSeverityMap, cached.edgeSeverityMap)
    }
    let resolved = allValidationIssues
    var nodeMap: [String: PolicyCanvasIssueSeverity] = [:]
    var edgeMap: [String: PolicyCanvasIssueSeverity] = [:]
    for issue in resolved {
      var nodeIDs: [String] = []
      if let nodeID = issue.issue.nodeId {
        nodeIDs.append(nodeID)
      }
      nodeIDs.append(contentsOf: issue.issue.nodeIds)
      for nodeID in nodeIDs {
        if let existing = nodeMap[nodeID] {
          nodeMap[nodeID] = min(existing, issue.severity)
        } else {
          nodeMap[nodeID] = issue.severity
        }
      }
      if let edgeID = issue.issue.edgeId {
        if let existing = edgeMap[edgeID] {
          edgeMap[edgeID] = min(existing, issue.severity)
        } else {
          edgeMap[edgeID] = issue.severity
        }
      }
    }
    validationCacheStorage = ValidationCacheEntry(
      token: token,
      nodeSeverityMap: nodeMap,
      edgeSeverityMap: edgeMap
    )
    return (nodeMap, edgeMap)
  }
}

/// One-shot record of a built severity map pair plus the token they were
/// built against. Kept as a struct so the cache write is a single
/// assignment to the `@ObservationIgnored` storage slot — no
/// per-field mutation path is exposed.
struct PolicyCanvasValidationCacheEntry {
  let token: PolicyCanvasViewModel.ValidationCacheToken
  let nodeSeverityMap: [String: PolicyCanvasIssueSeverity]
  let edgeSeverityMap: [String: PolicyCanvasIssueSeverity]
}

extension PolicyCanvasViewModel {
  typealias ValidationCacheEntry = PolicyCanvasValidationCacheEntry
}
