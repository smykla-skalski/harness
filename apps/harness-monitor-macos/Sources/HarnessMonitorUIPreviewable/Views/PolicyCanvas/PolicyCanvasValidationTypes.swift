import HarnessMonitorKit

struct PolicyCanvasValidationWorkerInput: Equatable, Sendable {
  let nodes: [PolicyCanvasNode]
  let edges: [PolicyCanvasEdge]
  let daemonIssues: [TaskBoardPolicyPipelineValidationIssue]

  init(
    nodes: [PolicyCanvasNode],
    edges: [PolicyCanvasEdge],
    daemonIssues: [TaskBoardPolicyPipelineValidationIssue]
  ) {
    self.nodes = nodes
    self.edges = edges
    self.daemonIssues = daemonIssues
  }
}

struct PolicyCanvasPreparedValidationInput: Equatable, Sendable {
  let nodes: [PolicyCanvasValidationNode]
  let edges: [PolicyCanvasEdge]
  let daemonIssues: [TaskBoardPolicyPipelineValidationIssue]
  let nodeIndex: [String: PolicyCanvasValidationNode]
  let nodeIDs: Set<String>
  let edgeIDs: Set<String>

  init(input: PolicyCanvasValidationWorkerInput) {
    let projectedNodes = input.nodes.map(PolicyCanvasValidationNode.init(node:))
    nodes = projectedNodes
    edges = input.edges
    daemonIssues = input.daemonIssues
    nodeIndex = Dictionary(uniqueKeysWithValues: projectedNodes.map { ($0.id, $0) })
    nodeIDs = Set(projectedNodes.map(\.id))
    edgeIDs = Set(input.edges.map(\.id))
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
