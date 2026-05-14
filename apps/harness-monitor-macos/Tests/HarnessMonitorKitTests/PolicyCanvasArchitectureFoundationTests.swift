import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas architecture foundation")
@MainActor
struct PolicyCanvasArchitectureFoundationTests {
  @Test("load does not clobber when document is dirty")
  func loadDoesNotClobberWhenDocumentIsDirty() {
    let viewModel = PolicyCanvasViewModel.sample()
    let beforeNodes = viewModel.nodes
    let beforeGroups = viewModel.groups
    let beforeEdges = viewModel.edges
    viewModel.documentDirty = true

    viewModel.load(
      document: archDocument(revision: 21),
      simulation: nil,
      audit: nil
    )

    #expect(viewModel.nodes.map(\.id) == beforeNodes.map(\.id))
    #expect(viewModel.groups.map(\.id) == beforeGroups.map(\.id))
    #expect(viewModel.edges.map(\.id) == beforeEdges.map(\.id))
    #expect(viewModel.documentDirty)
  }

  @Test("load applies when document is clean")
  func loadAppliesWhenDocumentIsClean() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.documentDirty = false
    let document = archDocument(revision: 22)

    viewModel.load(document: document, simulation: nil, audit: nil)

    #expect(viewModel.nodes.contains { $0.id == "arch-node-intake" })
    #expect(viewModel.groups.contains { $0.id == "arch-group-dispatch" })
    #expect(viewModel.edges.contains { $0.id == "arch-edge-intake-decision" })
    #expect(!viewModel.documentDirty)
  }

  @Test("set zoom does not mark document dirty")
  func setZoomDoesNotMarkDocumentDirty() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.documentDirty = false
    viewModel.viewportDirty = false

    viewModel.setZoom(1.2)

    #expect(!viewModel.documentDirty)
    #expect(viewModel.viewportDirty)
    #expect(abs(viewModel.zoom - 1.2) < 0.0001)
  }

  @Test("pending update exposed when dirty")
  func pendingUpdateExposedWhenDirty() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.documentDirty = true
    let document = archDocument(revision: 23)

    viewModel.load(document: document, simulation: nil, audit: nil)

    #expect(viewModel.pendingDocumentUpdate != nil)
    #expect(viewModel.pendingDocumentUpdate?.document?.revision == 23)
  }

  @Test("apply pending update overwrites and clears dirty")
  func applyPendingUpdateOverwritesAndClearsDirty() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.documentDirty = true
    let document = archDocument(revision: 24)
    viewModel.load(document: document, simulation: nil, audit: nil)

    viewModel.applyPendingUpdate()

    #expect(viewModel.nodes.contains { $0.id == "arch-node-intake" })
    #expect(viewModel.edges.contains { $0.id == "arch-edge-intake-decision" })
    #expect(!viewModel.documentDirty)
    #expect(viewModel.pendingDocumentUpdate == nil)
  }

  @Test("load then export then load is idempotent")
  func loadThenExportThenLoadIsIdempotent() {
    let firstVM = PolicyCanvasViewModel.sample()
    let document = archDocument(revision: 40)

    firstVM.load(document: document, simulation: nil, audit: nil)
    let exported = firstVM.exportDocument()

    let secondVM = PolicyCanvasViewModel.sample()
    secondVM.load(document: exported, simulation: nil, audit: nil)

    #expect(secondVM.nodes.map(\.id).sorted() == firstVM.nodes.map(\.id).sorted())
    #expect(secondVM.edges.map(\.id).sorted() == firstVM.edges.map(\.id).sorted())
    #expect(secondVM.groups.map(\.id).sorted() == firstVM.groups.map(\.id).sorted())

    // Node positions survive the round-trip (modulo grid snap, which is a
    // no-op for grid-aligned layout coordinates from the document).
    for nodeID in firstVM.nodes.map(\.id) {
      let first = firstVM.node(nodeID)?.position
      let second = secondVM.node(nodeID)?.position
      #expect(first == second)
    }

    // Re-exporting twice produces an identical document.
    let reexported = secondVM.exportDocument()
    #expect(reexported == exported)
  }

  @Test("set zoom then incoming document still applies")
  func setZoomThenIncomingDocumentStillApplies() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.documentDirty = false
    viewModel.viewportDirty = false

    viewModel.setZoom(1.3)
    #expect(viewModel.viewportDirty)
    #expect(!viewModel.documentDirty)

    let document = archDocument(revision: 50)
    viewModel.load(document: document, simulation: nil, audit: nil)

    // Document applied (not staged) because documentDirty was false. Only
    // viewport dirty must not gate the load seam.
    #expect(viewModel.pendingDocumentUpdate == nil)
    #expect(viewModel.nodes.count == document.nodes.count)
    #expect(viewModel.nodes.contains { $0.id == "arch-node-intake" })
    #expect(!viewModel.documentDirty)
  }

  @Test("same-revision republish is silent")
  func sameRevisionRepublishIsSilent() {
    let viewModel = PolicyCanvasViewModel.sample()
    let document = archDocument(revision: 30)
    viewModel.load(document: document, simulation: nil, audit: nil)
    // User makes a local edit AFTER load. documentDirty = true.
    viewModel.dragNode("arch-node-intake", translation: CGSize(width: 40, height: 0))
    viewModel.endNodeDrag("arch-node-intake", translation: CGSize(width: 40, height: 0))
    let positionAfterDrag = viewModel.node("arch-node-intake")?.position

    // Republish at the same revision — should neither stage nor replace.
    viewModel.load(document: document, simulation: nil, audit: nil)

    #expect(viewModel.documentDirty)
    #expect(viewModel.pendingDocumentUpdate == nil)
    #expect(viewModel.node("arch-node-intake")?.position == positionAfterDrag)
  }

  @Test("hasPendingDocumentUpdate mirrors pendingDocumentUpdate across lifecycle")
  func hasPendingDocumentUpdateMirrorsStorage() {
    let viewModel = PolicyCanvasViewModel.sample()
    // Initial state: nothing pending, mirror is false.
    #expect(viewModel.pendingDocumentUpdate == nil)
    #expect(viewModel.hasPendingDocumentUpdate == false)

    // Dirty + differing-revision incoming → pending is set, mirror flips true.
    viewModel.documentDirty = true
    viewModel.load(document: archDocument(revision: 70), simulation: nil, audit: nil)
    #expect(viewModel.pendingDocumentUpdate != nil)
    #expect(viewModel.hasPendingDocumentUpdate == true)

    // After applyPendingUpdate(): storage cleared, mirror flips false.
    viewModel.applyPendingUpdate()
    #expect(viewModel.pendingDocumentUpdate == nil)
    #expect(viewModel.hasPendingDocumentUpdate == false)
  }

  @Test("same-revision republish without fresh sim preserves latestSimulation")
  func sameRevisionRepublishPreservesLatestSimulation() {
    let viewModel = PolicyCanvasViewModel.sample()
    let document = archDocument(revision: 60)
    let simulation = archSimulation(revision: 60)
    viewModel.load(document: document, simulation: simulation, audit: nil)
    #expect(viewModel.latestSimulation == simulation)

    // Same-revision republish with no fresh sim and no audit. The old
    // simulation is still valid for this revision; the seam must not nil it.
    viewModel.load(document: document, simulation: nil, audit: nil)

    #expect(viewModel.latestSimulation == simulation)
  }

  private func archDocument(revision: UInt64) -> TaskBoardPolicyPipelineDocument {
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
          title: "Decision",
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
          TaskBoardPolicyPipelineNodeLayout(nodeId: "arch-node-decision", x: 320, y: 60),
        ]
      ),
      policyTraceIds: ["arch-trace-\(revision)"]
    )
  }

  private func archSimulation(revision: UInt64) -> TaskBoardPolicyPipelineSimulationResult {
    TaskBoardPolicyPipelineSimulationResult(
      revision: revision,
      traceId: "arch-trace-\(revision)",
      simulatedAt: "2026-05-14T12:00:00Z",
      succeeded: true,
      validation: TaskBoardPolicyPipelineValidation(isValid: true)
    )
  }
}
