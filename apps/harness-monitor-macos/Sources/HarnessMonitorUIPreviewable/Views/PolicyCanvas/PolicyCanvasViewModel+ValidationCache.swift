import Foundation
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
    routeComputationGeneration &+= 1
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
    (validationPresentation.nodeSeverityMap, validationPresentation.edgeSeverityMap)
  }

  func applyValidationPresentation(_ presentation: PolicyCanvasValidationPresentation) {
    guard validationPresentation != presentation else { return }
    validationPresentation = presentation
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

struct PolicyCanvasValidationWorkerKey: Equatable {
  let graphGeneration: UInt64
  let nodeCount: Int
  let edgeCount: Int
  let groupCount: Int
  let simulationRevision: UInt64?
  let simulationIssueCount: Int
  let simulationValid: Bool
}

struct PolicyCanvasValidationPresentation: Equatable, Sendable {
  static let empty = Self(issues: [], nodeSeverityMap: [:], edgeSeverityMap: [:])

  let issues: [PolicyCanvasResolvedIssue]
  let nodeSeverityMap: [String: PolicyCanvasIssueSeverity]
  let edgeSeverityMap: [String: PolicyCanvasIssueSeverity]
}

actor PolicyCanvasValidationWorker {
  private var cachedInput: PolicyCanvasValidationWorkerInput?
  private var cachedOutput = PolicyCanvasValidationPresentation.empty

  func compute(input: PolicyCanvasValidationWorkerInput) -> PolicyCanvasValidationPresentation {
    guard input != cachedInput else {
      return cachedOutput
    }
    let resolved = Self.resolvedIssues(input: input)
    cachedInput = input
    cachedOutput = PolicyCanvasValidationPresentation(
      issues: resolved,
      nodeSeverityMap: Self.nodeSeverityMap(for: resolved),
      edgeSeverityMap: Self.edgeSeverityMap(for: resolved)
    )
    return cachedOutput
  }

  func waitForIdle() async {}

  private static func resolvedIssues(
    input: PolicyCanvasValidationWorkerInput
  ) -> [PolicyCanvasResolvedIssue] {
    let daemon = input.daemonIssues.enumerated().map { offset, issue in
      resolvedIssue(issue: issue, origin: "daemon", index: offset, input: input)
    }
    let local = validateGraph(input: input).enumerated().map { offset, issue in
      resolvedIssue(issue: issue, origin: "local", index: offset, input: input)
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

  private static func validateGraph(
    input: PolicyCanvasValidationWorkerInput
  ) -> [TaskBoardPolicyPipelineValidationIssue] {
    var issues: [TaskBoardPolicyPipelineValidationIssue] = []
    if let cycle = detectCycle(input: input) {
      issues.append(
        TaskBoardPolicyPipelineValidationIssue(
          code: "cycle",
          message: "Cycle detected across \(cycle.joined(separator: ", "))",
          nodeIds: cycle
        )
      )
    }
    for orphan in detectOrphanNodes(input: input) {
      issues.append(
        TaskBoardPolicyPipelineValidationIssue(
          code: "orphan_node",
          message: "Node \(orphan) has no connections and is not in a group",
          nodeId: orphan
        )
      )
    }
    for duplicate in detectDuplicateTitles(input: input) {
      issues.append(
        TaskBoardPolicyPipelineValidationIssue(
          code: "duplicate_label",
          message: "\(duplicate.nodeIds.count) nodes share the title \"\(duplicate.title)\"",
          nodeIds: duplicate.nodeIds
        )
      )
    }
    for mismatch in detectErrorIntoAllowEdges(input: input) {
      issues.append(
        TaskBoardPolicyPipelineValidationIssue(
          code: "error_into_allow",
          message:
            "Error edge \"\(mismatch.edgeLabel)\" terminates at "
            + "\"\(mismatch.targetLabel)\" - verify intended",
          nodeId: mismatch.targetNodeId,
          edgeId: mismatch.edgeId
        )
      )
    }
    return issues
  }

  private static func detectCycle(input: PolicyCanvasValidationWorkerInput) -> [String]? {
    var adjacency: [String: [String]] = [:]
    for edge in input.edges {
      adjacency[edge.source.nodeID, default: []].append(edge.target.nodeID)
    }
    var visited = Set<String>()
    var onStack = Set<String>()
    for node in input.nodes where !visited.contains(node.id) {
      var stack: [(id: String, frontier: [String])] = [(node.id, adjacency[node.id] ?? [])]
      onStack.insert(node.id)
      while let top = stack.last {
        if let next = top.frontier.first {
          stack[stack.count - 1].frontier.removeFirst()
          if onStack.contains(next) {
            var cycle = stack.map(\.id)
            cycle.append(next)
            guard let start = cycle.firstIndex(of: next) else {
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

  private static func detectDuplicateTitles(
    input: PolicyCanvasValidationWorkerInput
  ) -> [PolicyCanvasDuplicateTitleGroup] {
    let bucketed = Dictionary(grouping: input.nodes, by: \.title)
    return
      bucketed
      .compactMap { title, members -> PolicyCanvasDuplicateTitleGroup? in
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, members.count > 1 else {
          return nil
        }
        return PolicyCanvasDuplicateTitleGroup(
          title: title,
          nodeIds: members.map(\.id).sorted()
        )
      }
      .sorted { $0.title < $1.title }
  }

  private static func detectOrphanNodes(input: PolicyCanvasValidationWorkerInput) -> [String] {
    var hasEdge = Set<String>()
    for edge in input.edges {
      hasEdge.insert(edge.source.nodeID)
      hasEdge.insert(edge.target.nodeID)
    }
    return
      input.nodes
      .filter { node in
        node.groupID == nil && !hasEdge.contains(node.id)
      }
      .map(\.id)
  }

  private static func detectErrorIntoAllowEdges(
    input: PolicyCanvasValidationWorkerInput
  ) -> [PolicyCanvasErrorIntoAllowMatch] {
    input.edges.compactMap { edge -> PolicyCanvasErrorIntoAllowMatch? in
      guard edge.kind == .error,
        let target = input.nodeIndex[edge.target.nodeID],
        let policyKind = target.policyKind,
        Self.allowingPolicyKinds.contains(policyKind.kind),
        let ruleId = policyKind.ruleId?.lowercased(),
        Self.allowingRuleSuffixes.contains(where: { ruleId.contains($0) })
      else {
        return nil
      }
      let label = edge.label.isEmpty ? edge.condition : edge.label
      return PolicyCanvasErrorIntoAllowMatch(
        edgeId: edge.id,
        edgeLabel: label.isEmpty ? edge.id : label,
        targetNodeId: target.id,
        targetLabel: target.title
      )
    }
  }

  private static func resolvedIssue(
    issue: TaskBoardPolicyPipelineValidationIssue,
    origin: String,
    index: Int,
    input: PolicyCanvasValidationWorkerInput
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
    if let edgeID = issue.edgeId, input.edgeIDs.contains(edgeID) {
      focus = .edge(edgeID)
    } else if let nodeID = issue.nodeId, input.nodeIDs.contains(nodeID) {
      focus = .node(nodeID)
    } else if let firstNodeID = issue.nodeIds.first(where: { input.nodeIDs.contains($0) }) {
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

  private static func nodeSeverityMap(
    for resolved: [PolicyCanvasResolvedIssue]
  ) -> [String: PolicyCanvasIssueSeverity] {
    var nodeMap: [String: PolicyCanvasIssueSeverity] = [:]
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
    }
    return nodeMap
  }

  private static func edgeSeverityMap(
    for resolved: [PolicyCanvasResolvedIssue]
  ) -> [String: PolicyCanvasIssueSeverity] {
    var edgeMap: [String: PolicyCanvasIssueSeverity] = [:]
    for issue in resolved {
      guard let edgeID = issue.issue.edgeId else { continue }
      if let existing = edgeMap[edgeID] {
        edgeMap[edgeID] = min(existing, issue.severity)
      } else {
        edgeMap[edgeID] = issue.severity
      }
    }
    return edgeMap
  }

  private static let allowingPolicyKinds: Set<String> = ["supervisor_rule"]
  private static let allowingRuleSuffixes: [String] = [
    "default-allow", "allow", "permit",
  ]
}

struct PolicyCanvasValidationWorkerInput: Equatable, Sendable {
  let nodes: [PolicyCanvasValidationNode]
  let edges: [PolicyCanvasEdge]
  let daemonIssues: [TaskBoardPolicyPipelineValidationIssue]
  let nodeIndex: [String: PolicyCanvasValidationNode]
  let nodeIDs: Set<String>
  let edgeIDs: Set<String>

  @MainActor
  init(
    nodes: [PolicyCanvasNode],
    edges: [PolicyCanvasEdge],
    daemonIssues: [TaskBoardPolicyPipelineValidationIssue]
  ) {
    self.nodes = nodes.map(PolicyCanvasValidationNode.init(node:))
    self.edges = edges
    self.daemonIssues = daemonIssues
    nodeIndex = Dictionary(uniqueKeysWithValues: self.nodes.map { ($0.id, $0) })
    nodeIDs = Set(self.nodes.map(\.id))
    edgeIDs = Set(edges.map(\.id))
  }
}

struct PolicyCanvasValidationNode: Equatable, Sendable {
  let id: String
  let title: String
  let groupID: String?
  let policyKind: TaskBoardPolicyPipelineNodeKind?

  init(node: PolicyCanvasNode) {
    id = node.id
    title = node.title
    groupID = node.groupID
    policyKind = node.policyKind
  }
}

private struct PolicyCanvasDuplicateTitleGroup {
  let title: String
  let nodeIds: [String]
}

private struct PolicyCanvasErrorIntoAllowMatch {
  let edgeId: String
  let edgeLabel: String
  let targetNodeId: String
  let targetLabel: String
}

extension PolicyCanvasViewModel {
  typealias ValidationCacheEntry = PolicyCanvasValidationCacheEntry
}
