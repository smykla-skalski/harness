import HarnessMonitorKit
import SwiftUI

extension PolicyCanvasViewModel {
  func load(
    document: TaskBoardPolicyPipelineDocument?,
    simulation: TaskBoardPolicyPipelineSimulationResult?,
    audit: TaskBoardPolicyPipelineAuditSummary?
  ) {
    guard let document else {
      latestSimulation = simulation ?? audit?.latestSimulation
      return
    }
    backingDocument = document
    latestSimulation = simulation ?? audit?.latestSimulation
    var loadedNodes = document.nodes.map {
      policyCanvasNode($0, layout: document.layout)
    }
    assignGroupMembership(from: document.groups, to: &loadedNodes)
    nodes = loadedNodes
    groups = document.groups.enumerated().map { offset, group in
      policyCanvasGroup(offset: offset, element: group, nodes: loadedNodes)
    }
    edges = document.edges.map(policyCanvasEdge)
    zoom = CGFloat(document.layout.zoom)
    resetNextNodeNumber()
    isDirty = false
    lastActionSummary = "Loaded revision \(document.revision)"
  }

  func exportDocument() -> TaskBoardPolicyPipelineDocument {
    let originalNodeKinds =
      backingDocument.map { document in
        Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, $0.kind) })
      } ?? [:]
    let originalEdgeConditions =
      backingDocument.map { document in
        Dictionary(uniqueKeysWithValues: document.edges.map { ($0.id, $0.condition) })
      } ?? [:]
    return TaskBoardPolicyPipelineDocument(
      schemaVersion: backingDocument?.schemaVersion ?? 2,
      revision: backingDocument?.revision ?? 1,
      mode: .draft,
      nodes: nodes.map { node in
        taskBoardPolicyNode(node, originalKind: originalNodeKinds[node.id])
      },
      edges: edges.map { edge in
        taskBoardPolicyEdge(edge, originalCondition: originalEdgeConditions[edge.id])
      },
      groups: groups.map { group in
        taskBoardPolicyGroup(group, nodes: nodes)
      },
      layout: TaskBoardPolicyPipelineLayout(
        zoom: Double(zoom),
        offset: backingDocument?.layout.offset ?? .zero,
        nodes: nodes.map(taskBoardPolicyNodeLayout)
      ),
      policyTraceIds: backingDocument?.policyTraceIds ?? []
    )
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
