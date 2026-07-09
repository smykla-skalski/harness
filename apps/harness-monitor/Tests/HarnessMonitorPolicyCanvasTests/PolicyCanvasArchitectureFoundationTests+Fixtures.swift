import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

extension PolicyCanvasArchitectureFoundationTests {
  func archDocument(
    revision: UInt64,
    decisionX: Int = 320,
    decisionTitle: String = "Decision"
  ) -> PolicyPipelineDocument {
    PolicyPipelineDocument(
      schemaVersion: 2,
      revision: revision,
      mode: .draft,
      nodes: [
        PolicyPipelineNode(
          id: "arch-node-intake",
          title: "Intake",
          kind: .actionGate(actions: [.spawnAgent]),
          groupId: "arch-group-dispatch",
          inputs: [PolicyPipelinePort(id: "in", title: "in")],
          outputs: [PolicyPipelinePort(id: "default", title: "default")]
        ),
        PolicyPipelineNode(
          id: "arch-node-decision",
          title: decisionTitle,
          kind: .actionGate(actions: [.spawnAgent]),
          groupId: "arch-group-dispatch",
          inputs: [PolicyPipelinePort(id: "in", title: "in")]
        ),
      ],
      edges: [
        PolicyPipelineEdge(
          id: "arch-edge-intake-decision",
          fromNodeId: "arch-node-intake",
          fromPort: "default",
          toNodeId: "arch-node-decision",
          toPort: "in"
        )
      ],
      groups: [
        PolicyPipelineGroup(
          id: "arch-group-dispatch",
          title: "Dispatch",
          nodeIds: ["arch-node-intake", "arch-node-decision"]
        )
      ],
      layout: PolicyPipelineLayout(
        nodes: [
          PolicyPipelineNodeLayout(nodeId: "arch-node-intake", x: 40, y: 60),
          PolicyPipelineNodeLayout(nodeId: "arch-node-decision", x: decisionX, y: 60),
        ]
      ),
      policyTraceIds: ["arch-trace-\(revision)"]
    )
  }

  func renamedGroupFlowDocument(revision: UInt64) -> PolicyPipelineDocument {
    PolicyPipelineDocument(
      schemaVersion: 2,
      revision: revision,
      mode: .draft,
      nodes: [
        PolicyPipelineNode(
          id: "custom-source",
          title: "Source",
          kind: .trigger(workflow: "default-task"),
          groupId: "custom-intake",
          inputs: [],
          outputs: [PolicyPipelinePort(id: "out", title: "out")]
        ),
        PolicyPipelineNode(
          id: "custom-sink",
          title: "Sink",
          kind: .actionGate(actions: [.spawnAgent]),
          groupId: "custom-sink",
          inputs: [PolicyPipelinePort(id: "in", title: "in")]
        ),
      ],
      edges: [
        PolicyPipelineEdge(
          id: "custom-edge",
          fromNodeId: "custom-source",
          fromPort: "out",
          toNodeId: "custom-sink",
          toPort: "in"
        )
      ],
      groups: [
        PolicyPipelineGroup(
          id: "custom-sink",
          title: "Sink",
          nodeIds: ["custom-sink"]
        ),
        PolicyPipelineGroup(
          id: "custom-intake",
          title: "Intake",
          nodeIds: ["custom-source"]
        ),
      ],
      layout: PolicyPipelineLayout(
        nodes: [
          PolicyPipelineNodeLayout(nodeId: "custom-source", x: 0, y: 0),
          PolicyPipelineNodeLayout(nodeId: "custom-sink", x: 0, y: 0),
        ]
      )
    )
  }

  func archSimulation(revision: UInt64) -> PolicyPipelineSimulationResult {
    PolicyPipelineSimulationResult(
      revision: revision,
      traceId: "arch-trace-\(revision)",
      simulatedAt: "2026-05-14T12:00:00Z",
      succeeded: true,
      validation: PolicyPipelineValidation(isValid: true)
    )
  }
}
