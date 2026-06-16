import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import HarnessMonitorPolicyModels

/// Construction helpers shared by every lab sample. They mirror the canonical
/// `PreviewFixtures.policyCanvasPipelineDocument()` idiom: ports are built from
/// plain id arrays, edges target a named port (defaulting to `in`), and the
/// document layout seeds rough left-to-right positions keyed by group depth so
/// the lab's force layout starts from a sane arrangement.
enum PolicyCanvasLabBuild {
  static func node(
    _ id: String,
    _ title: String,
    _ kind: PolicyGraphNodeKind,
    group: String,
    inputs: [String] = [],
    outputs: [String] = []
  ) -> TaskBoardPolicyPipelineNode {
    TaskBoardPolicyPipelineNode(
      id: id,
      title: title,
      kind: kind,
      groupId: group,
      inputs: inputs.map { TaskBoardPolicyPipelinePort(id: $0, title: $0) },
      outputs: outputs.map { TaskBoardPolicyPipelinePort(id: $0, title: $0) }
    )
  }

  static func edge(
    _ id: String,
    _ fromNode: String,
    _ fromPort: String,
    _ toNode: String,
    toPort: String = "in",
    label: String,
    condition: TaskBoardPolicyPipelineEdgeCondition = .always
  ) -> TaskBoardPolicyPipelineEdge {
    TaskBoardPolicyPipelineEdge(
      id: id,
      fromNodeId: fromNode,
      fromPort: fromPort,
      toNodeId: toNode,
      toPort: toPort,
      label: label,
      condition: condition
    )
  }

  static func group(
    _ id: String,
    _ title: String,
    _ color: String,
    _ nodeIds: [String]
  ) -> TaskBoardPolicyPipelineGroup {
    TaskBoardPolicyPipelineGroup(id: id, title: title, color: color, nodeIds: nodeIds)
  }

  /// Builds the document and seeds a left-to-right layout. Each node's seed
  /// column comes from its group's first-seen order; the row spreads members of
  /// that group vertically. Force layout refines from here.
  static func document(
    nodes: [TaskBoardPolicyPipelineNode],
    edges: [TaskBoardPolicyPipelineEdge],
    groups: [TaskBoardPolicyPipelineGroup],
    mode: TaskBoardPolicyPipelineMode = .draft,
    revision: UInt64 = 1
  ) -> TaskBoardPolicyPipelineDocument {
    TaskBoardPolicyPipelineDocument(
      schemaVersion: 2,
      revision: revision,
      mode: mode,
      nodes: nodes,
      edges: edges,
      groups: groups,
      layout: TaskBoardPolicyPipelineLayout(nodes: seedLayout(nodes: nodes, groups: groups)),
      policyTraceIds: ["trace-lab-sample-\(revision)"]
    )
  }

  private static func seedLayout(
    nodes: [TaskBoardPolicyPipelineNode],
    groups: [TaskBoardPolicyPipelineGroup]
  ) -> [TaskBoardPolicyPipelineNodeLayout] {
    let columnByGroup = Dictionary(
      uniqueKeysWithValues: groups.enumerated().map { ($0.element.id, $0.offset) }
    )
    var rowByGroup: [String: Int] = [:]
    return nodes.map { node in
      let group = node.groupId ?? ""
      let column = columnByGroup[group] ?? 0
      let row = rowByGroup[group, default: 0]
      rowByGroup[group] = row + 1
      return TaskBoardPolicyPipelineNodeLayout(
        nodeId: node.id,
        x: column * 280,
        y: row * 130
      )
    }
  }
}

/// Short forwarding shims so sample definitions inside `PolicyCanvasLabSamples`
/// extensions can call `node` / `edge` / `group` unqualified, keeping the dense
/// graph literals within the line-length budget.
extension PolicyCanvasLabSamples {
  static func node(
    _ id: String,
    _ title: String,
    _ kind: PolicyGraphNodeKind,
    group: String,
    inputs: [String] = [],
    outputs: [String] = []
  ) -> TaskBoardPolicyPipelineNode {
    PolicyCanvasLabBuild.node(
      id, title, kind, group: group, inputs: inputs, outputs: outputs
    )
  }

  static func edge(
    _ id: String,
    _ fromNode: String,
    _ fromPort: String,
    _ toNode: String,
    toPort: String = "in",
    label: String,
    condition: TaskBoardPolicyPipelineEdgeCondition = .always
  ) -> TaskBoardPolicyPipelineEdge {
    PolicyCanvasLabBuild.edge(
      id, fromNode, fromPort, toNode, toPort: toPort, label: label, condition: condition
    )
  }

  static func group(
    _ id: String,
    _ title: String,
    _ color: String,
    _ nodeIds: [String]
  ) -> TaskBoardPolicyPipelineGroup {
    PolicyCanvasLabBuild.group(id, title, color, nodeIds)
  }

  static func document(
    nodes: [TaskBoardPolicyPipelineNode],
    edges: [TaskBoardPolicyPipelineEdge],
    groups: [TaskBoardPolicyPipelineGroup]
  ) -> TaskBoardPolicyPipelineDocument {
    PolicyCanvasLabBuild.document(nodes: nodes, edges: edges, groups: groups)
  }
}
