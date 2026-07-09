import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

struct PolicyCanvasDocumentExportPayload: Sendable {
  let nodes: [PolicyCanvasNode]
  let groups: [PolicyCanvasGroup]
  let edges: [PolicyCanvasEdge]
  let zoom: CGFloat
  let routingHints: PolicyCanvasLayoutRoutingHints?
  let backingDocument: PolicyPipelineDocument?

  func exportDocument() -> PolicyPipelineDocument {
    let exportNodes = policyCanvasOptimizedPortOrder(nodes: nodes, edges: edges)
    let reconciledGroups = reconciledGroups(nodes: exportNodes)
    let originalNodeKinds =
      backingDocument.map { document in
        Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id.rawValue, $0.kind) })
      } ?? [:]
    let originalEdgeConditions =
      backingDocument.map { document in
        Dictionary(uniqueKeysWithValues: document.edges.map { ($0.id.rawValue, $0.condition) })
      } ?? [:]
    let liveNodeIDs = Set(exportNodes.map(\.id))
    return PolicyPipelineDocument(
      schemaVersion: backingDocument?.schemaVersion ?? 2,
      revision: backingDocument?.revision ?? 1,
      mode: .draft,
      nodes: exportNodes.map { node in
        policyNode(node, originalKind: originalNodeKinds[node.id])
      },
      edges: edges.flatMap { edge -> [PolicyPipelineEdge] in
        guard liveNodeIDs.contains(edge.source.nodeID) else { return [] }
        return policyCanvasDaemonEdges(
          for: edge,
          nodes: exportNodes,
          originalConditions: originalEdgeConditions
        )
        .filter { liveNodeIDs.contains($0.toNodeId.rawValue) }
      },
      groups: reconciledGroups.map { group in
        policyGroup(group, nodes: exportNodes)
      },
      layout: PolicyPipelineLayout(
        zoom: Double(zoom),
        offset: backingDocument?.layout.offset ?? .zero,
        nodes: exportNodes.map(policyNodeLayout),
        routingHints: policyRoutingHints(routingHints)
      ),
      policyTraceIds: backingDocument?.policyTraceIds ?? []
    )
  }

  func runLocalPreflight() async -> Int {
    let validationPresentation = await PolicyCanvasValidationWorker().compute(
      input: PolicyCanvasValidationWorkerInput(
        nodes: policyCanvasOptimizedPortOrder(nodes: nodes, edges: edges),
        edges: edges,
        daemonIssues: []
      )
    )
    return validationPresentation.issues.filter { issue in
      issue.severity == .error
    }
    .count
  }

  private func reconciledGroups(nodes exportNodes: [PolicyCanvasNode]) -> [PolicyCanvasGroup] {
    let nodesByGroupID = Dictionary(
      grouping: exportNodes.compactMap { node -> (String, PolicyCanvasNode)? in
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
