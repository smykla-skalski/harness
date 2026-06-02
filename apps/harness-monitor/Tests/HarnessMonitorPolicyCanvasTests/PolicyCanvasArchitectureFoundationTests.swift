import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

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

  @Test("clean legacy layout is promoted to manual provenance on export")
  func cleanLegacyLayoutPromotesManualProvenanceOnExport() {
    let viewModel = PolicyCanvasViewModel.sample()
    let document = archDocument(revision: 41)
    #expect(document.layout.nodes.allSatisfy { $0.source == nil })

    viewModel.load(document: document, simulation: nil, audit: nil)

    #expect(viewModel.nodes.allSatisfy { $0.layoutSource == .manual })
    let exported = viewModel.exportDocument()
    #expect(exported.layout.nodes.allSatisfy { $0.source == .manual })
  }

  @Test("automatic layout writes auto provenance for repaired legacy layout")
  func automaticLayoutWritesAutoProvenanceForRepairedLegacyLayout() {
    let viewModel = PolicyCanvasViewModel.sample()
    let document = overlappingDefaultPolicyDocument(revision: 42)
    #expect(document.layout.nodes.allSatisfy { $0.source == nil })

    viewModel.load(document: document, simulation: nil, audit: nil)

    #expect(viewModel.nodes.allSatisfy { $0.layoutSource == .auto })
    let exported = viewModel.exportDocument()
    #expect(exported.layout.nodes.allSatisfy { $0.source == .auto })
  }

  @Test("automatic layout follows graph flow instead of hard-coded group ids")
  func automaticLayoutFollowsGraphFlowInsteadOfHardCodedGroupIDs() {
    let viewModel = PolicyCanvasViewModel.sample()
    let document = renamedGroupFlowDocument(revision: 43)

    viewModel.load(document: document, simulation: nil, audit: nil)

    let groupFrames = Dictionary(uniqueKeysWithValues: viewModel.groups.map { ($0.id, $0.frame) })
    guard
      let intakeFrame = groupFrames["custom-intake"],
      let sinkFrame = groupFrames["custom-sink"]
    else {
      Issue.record("Expected custom flow groups after load")
      return
    }
    #expect(intakeFrame.minX < sinkFrame.minX)
    #expect(viewModel.nodes.allSatisfy { $0.layoutSource == .auto })
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

  @Test("same-revision different document keeps local edits without bannering when dirty")
  func sameRevisionDifferentDocumentKeepsLocalEditsWhenDirty() {
    let viewModel = PolicyCanvasViewModel.sample()
    let seeded = archDocument(revision: 31)
    viewModel.load(document: seeded, simulation: nil, audit: nil)
    viewModel.dragNode("arch-node-intake", translation: CGSize(width: 40, height: 0))
    viewModel.endNodeDrag("arch-node-intake", translation: CGSize(width: 40, height: 0))
    let liveDocument = archDocument(revision: 31, decisionX: 520)

    // A re-serialized document at the SAME revision is not a remote change: it
    // must neither stage a pending update (the spurious "Remote changes
    // available" banner) nor replace the user's in-progress edits. Only a
    // strictly-newer revision is treated as a remote change.
    viewModel.load(document: liveDocument, simulation: nil, audit: nil)

    #expect(viewModel.documentDirty)
    #expect(viewModel.pendingDocumentUpdate == nil)
    #expect(viewModel.node("arch-node-decision")?.position != CGPoint(x: 520, y: 60))
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

  @Test("same-revision republish clears in-flight rubber-band and highlights")
  func sameRevisionRepublishClearsTransientGestureState() {
    let viewModel = PolicyCanvasViewModel.sample()
    let document = archDocument(revision: 80)
    viewModel.load(document: document, simulation: nil, audit: nil)

    // Simulate an in-flight rubber-band drag plus highlighted port and group.
    viewModel.beginPendingEdge(
      sourceNodeID: "arch-node-intake",
      sourcePortID: "default"
    )
    viewModel.setInputTargeted(true, nodeID: "arch-node-decision", portID: "in")
    viewModel.setGroupDropTargeted(true, groupID: "arch-group-dispatch")
    #expect(viewModel.hasPendingEdge == true)
    #expect(viewModel.highlightedInput != nil)
    #expect(viewModel.highlightedGroupID != nil)

    // Daemon emits an audit-only republish at the same revision (no document
    // change). The transient affordances must clear — their anchors may not
    // point at the same screen position after layout reconciles.
    viewModel.load(document: document, simulation: nil, audit: nil)

    #expect(viewModel.pendingEdgePreview == nil)
    #expect(viewModel.hasPendingEdge == false)
    #expect(viewModel.highlightedInput == nil)
    #expect(viewModel.highlightedGroupID == nil)
  }

  @Test("same-revision republish rewinds the palette drop cursor")
  func sameRevisionRepublishRewindsPaletteAnchor() {
    let viewModel = PolicyCanvasViewModel.sample()
    let document = archDocument(revision: 90)
    viewModel.load(document: document, simulation: nil, audit: nil)
    // Advance the palette cursor away from the initial anchor. The returned
    // point depends on which slots the arch-doc nodes occupy, so the
    // post-advance ANCHOR is the invariant we check, not the returned point.
    _ = viewModel.nextPaletteDropCenter()
    _ = viewModel.nextPaletteDropCenter()
    #expect(viewModel.nextPaletteDropAnchor != PolicyCanvasLayout.initialPaletteDropAnchor)

    // Same-revision republish must reset the diagonal cursor; otherwise an
    // audit-only restore leaves the next click landing on a drifting offset.
    viewModel.load(document: document, simulation: nil, audit: nil)

    #expect(viewModel.nextPaletteDropAnchor == PolicyCanvasLayout.initialPaletteDropAnchor)
  }

  @Test("loadIfChanged applies same-revision different document when clean")
  func loadIfChangedAppliesSameRevisionDifferentDocumentWhenClean() {
    let viewModel = PolicyCanvasViewModel.sample()
    let previewSeed = archDocument(revision: 91, decisionX: 320)
    viewModel.load(document: previewSeed, simulation: nil, audit: nil)
    let liveDocument = archDocument(
      revision: 91,
      decisionX: 520,
      decisionTitle: "Decision Live"
    )

    viewModel.loadIfChanged(document: liveDocument, simulation: nil, audit: nil)

    #expect(viewModel.backingDocument == liveDocument)
    #expect(viewModel.pendingDocumentUpdate == nil)
    #expect(viewModel.node("arch-node-decision")?.title == "Decision Live")
  }

  @Test("routingObstacles keeps nodes and group titles as hard obstacles")
  func routingObstaclesScopesGroupsByEndpoints() {
    let viewModel = PolicyCanvasViewModel.sample()
    let expectedNodeFrames = viewModel.nodes.map { node in
      CGRect(origin: node.position, size: PolicyCanvasLayout.nodeSize)
    }
    let expectedTitleFrames = policyCanvasGroupTitleFrames(viewModel.groups)
    guard let groupFrame = viewModel.groups.first?.frame else {
      Issue.record("sample document is expected to contain at least one group")
      return
    }

    let insideGroupPoint = CGPoint(x: groupFrame.midX, y: groupFrame.midY)
    let outsideGroupPoint = CGPoint(x: groupFrame.maxX + 400, y: groupFrame.maxY + 400)

    let insideObstacles = viewModel.routingObstacles(
      source: insideGroupPoint,
      target: outsideGroupPoint
    )
    #expect(insideObstacles.count == expectedNodeFrames.count + expectedTitleFrames.count)
    for frame in expectedNodeFrames {
      #expect(insideObstacles.contains(frame))
    }
    for frame in expectedTitleFrames {
      #expect(insideObstacles.contains(frame))
    }
    #expect(!insideObstacles.contains(groupFrame))

    let farPointA = CGPoint(x: outsideGroupPoint.x, y: outsideGroupPoint.y)
    let farPointB = CGPoint(x: outsideGroupPoint.x + 200, y: outsideGroupPoint.y + 200)
    let outsideObstacles = viewModel.routingObstacles(source: farPointA, target: farPointB)
    #expect(outsideObstacles.count == expectedNodeFrames.count + expectedTitleFrames.count)
    for frame in expectedTitleFrames {
      #expect(outsideObstacles.contains(frame))
    }
    #expect(!outsideObstacles.contains(groupFrame))
  }
}
