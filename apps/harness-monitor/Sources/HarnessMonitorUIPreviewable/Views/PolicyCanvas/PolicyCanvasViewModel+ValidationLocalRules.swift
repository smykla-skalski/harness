import Foundation
import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms

extension PolicyCanvasViewModel {
  // MARK: - Local validators

  /// Returns the first cycle found in the directed edge graph as a list of
  /// node ids in visit order, or nil when the graph is acyclic. Uses
  /// iterative DFS with an explicit `onStack` set to detect back-edges in
  /// the directed graph; tree forward-edges and cross-edges (visited but
  /// not on the current path) are ignored. The stack stores both the node
  /// id and a mutable frontier so we can preserve neighbor ordering and
  /// avoid recomputing adjacency lookups.
  func detectCycle() -> [String]? {
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

  struct ErrorIntoAllowMatch {
    let edgeId: String
    let edgeLabel: String
    let targetNodeId: String
    let targetLabel: String
  }

  private static let allowingPolicyKinds: Set<String> = ["supervisor_rule"]
  private static let allowingRuleSuffixes: [String] = [
    "default-allow", "allow", "permit",
  ]

  func detectErrorIntoAllowEdges() -> [ErrorIntoAllowMatch] {
    edges.compactMap { edge -> ErrorIntoAllowMatch? in
      guard edge.kind == .error,
        let target = node(edge.target.nodeID),
        let policyKind = target.policyKind,
        Self.allowingPolicyKinds.contains(policyKind.kind),
        let ruleId = policyKind.ruleId?.lowercased(),
        Self.allowingRuleSuffixes.contains(where: { ruleId.contains($0) })
      else {
        return nil
      }
      let label = edge.label.isEmpty ? edge.condition : edge.label
      return ErrorIntoAllowMatch(
        edgeId: edge.id,
        edgeLabel: label.isEmpty ? edge.id : label,
        targetNodeId: target.id,
        targetLabel: target.title
      )
    }
  }

  struct DuplicateTitleGroup {
    let title: String
    let nodeIds: [String]
  }

  func detectDuplicateTitles() -> [DuplicateTitleGroup] {
    let bucketed = Dictionary(grouping: nodes, by: \.title)
    return
      bucketed
      .compactMap { title, members -> DuplicateTitleGroup? in
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, members.count > 1 else {
          return nil
        }
        return DuplicateTitleGroup(
          title: title,
          nodeIds: members.map(\.id).sorted()
        )
      }
      .sorted { $0.title < $1.title }
  }

  func detectOrphanNodes() -> [String] {
    var hasEdge = Set<String>()
    for edge in edges {
      hasEdge.insert(edge.source.nodeID)
      hasEdge.insert(edge.target.nodeID)
    }
    return
      nodes
      .filter { node in
        node.groupID == nil && !hasEdge.contains(node.id)
      }
      .map(\.id)
  }

  func resolvedIssue(
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
