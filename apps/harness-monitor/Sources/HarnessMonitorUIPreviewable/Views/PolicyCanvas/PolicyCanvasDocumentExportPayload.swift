import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

struct PolicyCanvasDocumentExportPayload: Sendable {
  let nodes: [PolicyCanvasNode]
  let groups: [PolicyCanvasGroup]
  let edges: [PolicyCanvasEdge]
  let zoom: CGFloat
  let routingHints: PolicyCanvasLayoutRoutingHints?
  let backingDocument: TaskBoardPolicyPipelineDocument?

  func exportDocument() -> TaskBoardPolicyPipelineDocument {
    let reconciledGroups = reconciledGroups()
    let originalNodeKinds =
      backingDocument.map { document in
        Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, $0.kind) })
      } ?? [:]
    let originalEdgeConditions =
      backingDocument.map { document in
        Dictionary(uniqueKeysWithValues: document.edges.map { ($0.id, $0.condition) })
      } ?? [:]
    let liveNodeIDs = Set(nodes.map(\.id))
    return TaskBoardPolicyPipelineDocument(
      schemaVersion: backingDocument?.schemaVersion ?? 2,
      revision: backingDocument?.revision ?? 1,
      mode: .draft,
      nodes: nodes.map { node in
        taskBoardPolicyNode(node, originalKind: originalNodeKinds[node.id])
      },
      edges: edges.flatMap { edge -> [TaskBoardPolicyPipelineEdge] in
        guard liveNodeIDs.contains(edge.source.nodeID) else { return [] }
        return policyCanvasDaemonEdges(
          for: edge,
          nodes: nodes,
          originalConditions: originalEdgeConditions
        )
        .filter { liveNodeIDs.contains($0.toNodeId) }
      },
      groups: reconciledGroups.map { group in
        taskBoardPolicyGroup(group, nodes: nodes)
      },
      layout: TaskBoardPolicyPipelineLayout(
        zoom: Double(zoom),
        offset: backingDocument?.layout.offset ?? .zero,
        nodes: nodes.map(taskBoardPolicyNodeLayout),
        routingHints: taskBoardPolicyRoutingHints(routingHints)
      ),
      policyTraceIds: backingDocument?.policyTraceIds ?? []
    )
  }

  func runLocalPreflight() async -> Int {
    let validationPresentation = await PolicyCanvasValidationWorker().compute(
      input: PolicyCanvasValidationWorkerInput(
        nodes: nodes,
        edges: edges,
        daemonIssues: []
      )
    )
    return validationPresentation.issues.filter { issue in
      issue.severity == .error
    }
    .count
  }

  private func reconciledGroups() -> [PolicyCanvasGroup] {
    let nodesByGroupID = Dictionary(
      grouping: nodes.compactMap { node -> (String, PolicyCanvasNode)? in
        guard let groupID = node.groupID else {
          return nil
        }
        return (groupID, node)
      }
    ) { $0.0 }
    .mapValues { entries in entries.map(\.1) }

    var nextGroups = groups
    for index in nextGroups.indices {
      guard
        let frame = policyCanvasGroupFrame(
          containing: nodesByGroupID[nextGroups[index].id] ?? []
        )
      else {
        continue
      }
      nextGroups[index].frame = frame
    }
    return nextGroups
  }
}
