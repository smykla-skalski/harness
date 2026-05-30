import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension PolicyCanvasArchitectureFoundationTests {
  func archDocument(
    revision: UInt64,
    decisionX: Int = 320,
    decisionTitle: String = "Decision"
  ) -> TaskBoardPolicyPipelineDocument {
    TaskBoardPolicyPipelineDocument(
      schemaVersion: 2,
      revision: revision,
      mode: .draft,
      nodes: [
        TaskBoardPolicyPipelineNode(
          id: "arch-node-intake",
          title: "Intake",
          kind: TaskBoardPolicyPipelineNodeKind(kind: "action_gate", actions: [.spawnAgent]),
          groupId: "arch-group-dispatch",
          inputs: [TaskBoardPolicyPipelinePort(id: "in", title: "in")],
          outputs: [TaskBoardPolicyPipelinePort(id: "default", title: "default")]
        ),
        TaskBoardPolicyPipelineNode(
          id: "arch-node-decision",
          title: decisionTitle,
          kind: TaskBoardPolicyPipelineNodeKind(kind: "action_gate", actions: [.spawnAgent]),
          groupId: "arch-group-dispatch",
          inputs: [TaskBoardPolicyPipelinePort(id: "in", title: "in")]
        ),
      ],
      edges: [
        TaskBoardPolicyPipelineEdge(
          id: "arch-edge-intake-decision",
          fromNodeId: "arch-node-intake",
          fromPort: "default",
          toNodeId: "arch-node-decision",
          toPort: "in"
        )
      ],
      groups: [
        TaskBoardPolicyPipelineGroup(
          id: "arch-group-dispatch",
          title: "Dispatch",
          nodeIds: ["arch-node-intake", "arch-node-decision"]
        )
      ],
      layout: TaskBoardPolicyPipelineLayout(
        nodes: [
          TaskBoardPolicyPipelineNodeLayout(nodeId: "arch-node-intake", x: 40, y: 60),
          TaskBoardPolicyPipelineNodeLayout(nodeId: "arch-node-decision", x: decisionX, y: 60),
        ]
      ),
      policyTraceIds: ["arch-trace-\(revision)"]
    )
  }

  func renamedGroupFlowDocument(revision: UInt64) -> TaskBoardPolicyPipelineDocument {
    TaskBoardPolicyPipelineDocument(
      schemaVersion: 2,
      revision: revision,
      mode: .draft,
      nodes: [
        TaskBoardPolicyPipelineNode(
          id: "custom-source",
          title: "Source",
          kind: TaskBoardPolicyPipelineNodeKind(kind: "trigger", workflow: "default-task"),
          groupId: "custom-intake",
          inputs: [],
          outputs: [TaskBoardPolicyPipelinePort(id: "out", title: "out")]
        ),
        TaskBoardPolicyPipelineNode(
          id: "custom-sink",
          title: "Sink",
          kind: TaskBoardPolicyPipelineNodeKind(kind: "action_gate", actions: [.spawnAgent]),
          groupId: "custom-sink",
          inputs: [TaskBoardPolicyPipelinePort(id: "in", title: "in")]
        ),
      ],
      edges: [
        TaskBoardPolicyPipelineEdge(
          id: "custom-edge",
          fromNodeId: "custom-source",
          fromPort: "out",
          toNodeId: "custom-sink",
          toPort: "in"
        )
      ],
      groups: [
        TaskBoardPolicyPipelineGroup(
          id: "custom-sink",
          title: "Sink",
          nodeIds: ["custom-sink"]
        ),
        TaskBoardPolicyPipelineGroup(
          id: "custom-intake",
          title: "Intake",
          nodeIds: ["custom-source"]
        ),
      ],
      layout: TaskBoardPolicyPipelineLayout(
        nodes: [
          TaskBoardPolicyPipelineNodeLayout(nodeId: "custom-source", x: 0, y: 0),
          TaskBoardPolicyPipelineNodeLayout(nodeId: "custom-sink", x: 0, y: 0),
        ]
      )
    )
  }

  func archSimulation(revision: UInt64) -> TaskBoardPolicyPipelineSimulationResult {
    TaskBoardPolicyPipelineSimulationResult(
      revision: revision,
      traceId: "arch-trace-\(revision)",
      simulatedAt: "2026-05-14T12:00:00Z",
      succeeded: true,
      validation: TaskBoardPolicyPipelineValidation(isValid: true)
    )
  }
}
