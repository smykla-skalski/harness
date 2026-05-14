import HarnessMonitorKit
import SwiftUI

// SHIM: Local cycle/orphan detection in this file duplicates daemon-side
// validation while daemon issue payloads carry generic messages without
// stable per-node severity or per-edge code attribution. Remove this entire
// validator (including `validateGraph()`, `detectCycle()`, and
// `detectOrphanNodes()`) once the daemon emits structured per-node/per-edge
// severity. The cost of the duplication is documented in the merge site near
// `allValidationIssues` (see "Dedup of daemon vs local issues is deferred").
// See plan P11.

/// Severity tier for a `TaskBoardPolicyPipelineValidationIssue`. The daemon
/// payload itself has no severity field; this mapping is local to the canvas
/// so the panel and inline marks can render a consistent visual weight without
/// the user having to read each issue code. Order is significant: `.error`
/// sorts above `.warning` in the panel and dominates the inline severity tone
/// when a node carries both.
enum PolicyCanvasIssueSeverity: Int, Comparable {
  case error = 0
  case warning = 1

  static func < (lhs: PolicyCanvasIssueSeverity, rhs: PolicyCanvasIssueSeverity) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  // SHIM: this allowlist maps known daemon codes to local severity tiers.
  // When the daemon adds a new error code, the fallback (`.warning`) will
  // silently downgrade it; this is acceptable while the panel still
  // surfaces every code, but the moment the daemon emits its own severity
  // field this whole switch should disappear. See P11 shim block at the
  // top of this file.

  /// Map a daemon-emitted code to a severity tier. Anything not explicitly
  /// classified falls back to `.warning` so unknown future codes still render
  /// in the panel and stay visible to the user.
  static func from(code: String) -> PolicyCanvasIssueSeverity {
    switch code {
    case "cycle",
      "dangling_edge",
      "duplicate_id",
      "invalid_port",
      "unsupported_schema_version",
      "orphan_node",
      "unsafe_high_risk_action":
      return .error
    default:
      return .warning
    }
  }

  var systemImage: String {
    switch self {
    case .error:
      "exclamationmark.triangle.fill"
    case .warning:
      "exclamationmark.circle.fill"
    }
  }

  var displayLabel: String {
    switch self {
    case .error:
      "Error"
    case .warning:
      "Warning"
    }
  }

  /// Foreground tone for inline marks and panel rows. Both pass WCAG AA
  /// contrast against the canvas dark backdrop (`#1A1F26` and darker): the
  /// system `.red` (light variant) renders ~5.1:1 on the inspector panel
  /// background, and `.yellow` renders ~10:1 on the same surface.
  var accentColor: Color {
    switch self {
    case .error:
      .red
    case .warning:
      .yellow
    }
  }
}

/// A canvas-scoped wrapper around the underlying validation issue. Adds the
/// severity classification, a stable identifier the SwiftUI list can use, and
/// the focus selection the click-to-jump action should apply. Stays equatable
/// for diffing in tests.
struct PolicyCanvasResolvedIssue: Identifiable, Equatable {
  let issue: TaskBoardPolicyPipelineValidationIssue
  let severity: PolicyCanvasIssueSeverity
  let id: String
  let focusSelection: PolicyCanvasSelection?
}

extension PolicyCanvasViewModel {
  /// Daemon-reported validation, when a simulation has been run. The chrome
  /// panel and inline marks both read through here so the surface stays in
  /// sync with the inspector summary; nil means "no simulation yet".
  var daemonValidationIssues: [TaskBoardPolicyPipelineValidationIssue] {
    latestSimulation?.validation.issues ?? []
  }

  /// Combined daemon + local issue list resolved into severities and stable
  /// ids. Sorted by severity ascending (errors first), then by code, then by
  /// originating order so duplicates from the daemon don't reshuffle on every
  /// reload.
  ///
  /// ADR: dedup of daemon vs local issues is deferred. When the daemon and
  /// the local validator both report a cycle that spans the same set of
  /// node ids, both entries surface in the panel. Rationale: until the
  /// daemon emits structured per-node severity (see the SHIM note at the
  /// top of this file), we cannot reliably match daemon-emitted cycle
  /// complaints against local-emitted ones — daemon `cycle` payloads have
  /// no canonical node-id ordering, and message strings differ. The cost
  /// of surfacing both is a duplicated row in the panel; the cost of
  /// dedupe-by-best-guess is silently swallowing one side. We pay the UX
  /// cost until the daemon side improves.
  var allValidationIssues: [PolicyCanvasResolvedIssue] {
    let daemon = daemonValidationIssues.enumerated().map { offset, issue in
      resolvedIssue(issue: issue, origin: "daemon", index: offset)
    }
    let local = validateGraph().enumerated().map { offset, issue in
      resolvedIssue(issue: issue, origin: "local", index: offset)
    }
    return (daemon + local).sorted { left, right in
      if left.severity != right.severity {
        return left.severity < right.severity
      }
      if left.issue.code != right.issue.code {
        return left.issue.code < right.issue.code
      }
      return left.id < right.id
    }
  }

  /// True when at least one resolved issue targets this node id (directly via
  /// `nodeId` or transitively via `nodeIds`).
  func hasIssues(forNode nodeID: String) -> Bool {
    severity(forNode: nodeID) != nil
  }

  /// Highest-severity tier resolved for this node, nil when there are no
  /// issues. Used by the inline node-card tint and the severity icon overlay.
  func severity(forNode nodeID: String) -> PolicyCanvasIssueSeverity? {
    nodeSeverityMap[nodeID]
  }

  /// True when at least one resolved issue targets this edge id.
  func hasIssues(forEdge edgeID: String) -> Bool {
    severity(forEdge: edgeID) != nil
  }

  /// Highest-severity tier resolved for this edge, nil when there are no
  /// issues. Used by the inline edge stroke tint.
  func severity(forEdge edgeID: String) -> PolicyCanvasIssueSeverity? {
    edgeSeverityMap[edgeID]
  }

  /// Pre-rolled `[nodeID: severity]` map. Backed by an `@ObservationIgnored`
  /// cache keyed on `ValidationCacheToken` (node/edge/group counts +
  /// simulation revision + invalidation generation). First read after any
  /// mutation rebuilds the map by walking `allValidationIssues` once;
  /// subsequent reads return the cached storage in O(1). Hot-path callers
  /// (`PolicyCanvasNodeCard`, `PolicyCanvasEdgeLayer`) must hoist this into
  /// a body-local `let` so per-row lookups skip the token comparison.
  ///
  /// Cache invalidation lives in `+ValidationCache.swift`; mutation sites
  /// that bypass the count token (drag-end position changes, group
  /// reflow, simulation install) call `invalidateValidationCache()` to
  /// bump the generation counter.
  var nodeSeverityMap: [String: PolicyCanvasIssueSeverity] {
    cachedSeverityMaps().nodes
  }

  /// Pre-rolled `[edgeID: severity]` map. See `nodeSeverityMap`.
  var edgeSeverityMap: [String: PolicyCanvasIssueSeverity] {
    cachedSeverityMaps().edges
  }

  /// Resolved issues affecting the currently selected node or edge. Used by
  /// the inspector panel so the selection-detail surface lists the
  /// component-scoped issues without the user opening the chrome panel.
  func resolvedIssues(for selection: PolicyCanvasSelection) -> [PolicyCanvasResolvedIssue] {
    allValidationIssues.filter { resolved in
      switch selection {
      case .node(let id):
        return resolved.issue.nodeId == id || resolved.issue.nodeIds.contains(id)
      case .edge(let id):
        return resolved.issue.edgeId == id
      case .group:
        return false
      }
    }
  }

  /// Local pre-flight invoked from `saveDraft` before the daemon round-trip.
  /// Returns the resolved local error issues so the caller can surface a
  /// fast-feedback warning, but does NOT block the save — the daemon is
  /// the source of truth, and the snapshot/restore frame around
  /// `exportDocument()` (Wave 2D) handles rollback when daemon rejects.
  ///
  /// History: an earlier revision of this method hard-blocked save when
  /// the local validator found errors. That was a #5 (rules) intervention
  /// fighting a #8 (feedback loop) intervention — the snapshot/restore is
  /// the structural answer to "daemon disagrees with me", and pre-empting
  /// it from the local side let local-clean + daemon-reject escape
  /// rollback. We now report what we found, emit a status warning, and
  /// let the save proceed.
  ///
  /// Returns the local error issues (warnings excluded). The view-side
  /// caller uses `isEmpty` to decide whether to emit a status warning,
  /// but never gates the daemon call on the result.
  func runLocalPreflight() -> [TaskBoardPolicyPipelineValidationIssue] {
    let issues = validateGraph()
    let errors = issues.filter { issue in
      PolicyCanvasIssueSeverity.from(code: issue.code) == .error
    }
    if !errors.isEmpty {
      notifyStatus(
        "Local validation warning - \(errors.count) issue(s); daemon will check"
      )
    }
    return errors
  }

  /// Move selection (and therefore the viewport scroll seam owned by the
  /// node/edge ForEach) to the offending component described by `issue`.
  /// Falls back to clearing selection when neither a node nor an edge id is
  /// usable so the action remains a no-op rather than throwing.
  func focusIssue(_ resolved: PolicyCanvasResolvedIssue) {
    guard let target = resolved.focusSelection else {
      return
    }
    select(target)
    notifyStatus("Focused \(resolved.issue.code)")
  }

  /// Run the local cycle + orphan detector. Returns a fresh issue array each
  /// call; daemon-side issues are not duplicated here. Detection is pure over
  /// the in-memory graph (no IO), so this is cheap to call from a computed
  /// property.
  func validateGraph() -> [TaskBoardPolicyPipelineValidationIssue] {
    var issues: [TaskBoardPolicyPipelineValidationIssue] = []
    if let cycle = detectCycle() {
      issues.append(
        TaskBoardPolicyPipelineValidationIssue(
          code: "cycle",
          message: "Cycle detected across \(cycle.joined(separator: ", "))",
          nodeIds: cycle
        )
      )
    }
    for orphan in detectOrphanNodes() {
      issues.append(
        TaskBoardPolicyPipelineValidationIssue(
          code: "orphan_node",
          message: "Node \(orphan) has no connections and is not in a group",
          nodeId: orphan
        )
      )
    }
    return issues
  }

  // MARK: - Local validators

  /// Returns the first cycle found in the directed edge graph as a list of
  /// node ids in visit order, or nil when the graph is acyclic. Uses
  /// iterative DFS with an explicit `onStack` set to detect back-edges in
  /// the directed graph; tree forward-edges and cross-edges (visited but
  /// not on the current path) are ignored. The stack stores both the node
  /// id and a mutable frontier so we can preserve neighbor ordering and
  /// avoid recomputing adjacency lookups.
  private func detectCycle() -> [String]? {
    var adjacency: [String: [String]] = [:]
    for edge in edges {
      adjacency[edge.source.nodeID, default: []].append(edge.target.nodeID)
    }
    var visited = Set<String>()
    var onStack = Set<String>()
    for node in nodes where !visited.contains(node.id) {
      var stack: [(id: String, frontier: [String])] = [(node.id, adjacency[node.id] ?? [])]
      onStack.insert(node.id)
      while let top = stack.last {
        if let next = top.frontier.first {
          stack[stack.count - 1].frontier.removeFirst()
          if onStack.contains(next) {
            // Back-edge to a node still on the current DFS path. Slice the
            // path from the first occurrence of `next` to its tail; the
            // stack invariant guarantees `next` appears in `stack.map(\.id)`
            // exactly once because we only push when `!visited.contains(next)`,
            // so `firstIndex(of:)` is total here.
            var cycle = stack.map(\.id)
            cycle.append(next)
            guard let start = cycle.firstIndex(of: next) else {
              // Unreachable by the stack invariant; fall back to returning
              // the captured path so a future bug surfaces a real cycle
              // rather than silently dropping it.
              return cycle
            }
            return Array(cycle[start...])
          }
          if !visited.contains(next) {
            onStack.insert(next)
            stack.append((next, adjacency[next] ?? []))
          }
        } else {
          let finished = stack.removeLast()
          visited.insert(finished.id)
          onStack.remove(finished.id)
        }
      }
    }
    return nil
  }

  /// Returns node ids that have neither incoming nor outgoing edges and are
  /// not members of any group. A node inside a group is treated as
  /// intentionally staged and is not reported, matching the daemon's notion
  /// of "lonely without context".
  private func detectOrphanNodes() -> [String] {
    var hasEdge = Set<String>()
    for edge in edges {
      hasEdge.insert(edge.source.nodeID)
      hasEdge.insert(edge.target.nodeID)
    }
    return nodes
      .filter { node in
        node.groupID == nil && !hasEdge.contains(node.id)
      }
      .map(\.id)
  }

  private func resolvedIssue(
    issue: TaskBoardPolicyPipelineValidationIssue,
    origin: String,
    index: Int
  ) -> PolicyCanvasResolvedIssue {
    let severity = PolicyCanvasIssueSeverity.from(code: issue.code)
    let stableID = [
      origin,
      issue.code,
      issue.nodeId ?? "",
      issue.edgeId ?? "",
      issue.id ?? "",
      String(index),
    ]
    .joined(separator: ":")
    let focus: PolicyCanvasSelection?
    if let edgeID = issue.edgeId, edges.contains(where: { $0.id == edgeID }) {
      focus = .edge(edgeID)
    } else if let nodeID = issue.nodeId, nodes.contains(where: { $0.id == nodeID }) {
      focus = .node(nodeID)
    } else if let firstNodeID = issue.nodeIds.first(where: { id in
      nodes.contains(where: { $0.id == id })
    }) {
      focus = .node(firstNodeID)
    } else {
      focus = nil
    }
    return PolicyCanvasResolvedIssue(
      issue: issue,
      severity: severity,
      id: stableID,
      focusSelection: focus
    )
  }
}
