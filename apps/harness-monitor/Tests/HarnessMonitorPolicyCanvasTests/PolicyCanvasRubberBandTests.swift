import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

@Suite("Policy canvas rubber band")
@MainActor
struct PolicyCanvasRubberBandTests {
  @Test("begin from valid output port stages a pending edge anchored to the port")
  func beginAnchorsToOutputPort() {
    let viewModel = makeCanvas()

    viewModel.beginPendingEdge(sourceNodeID: "source", sourcePortID: "output-event")

    guard let preview = viewModel.pendingEdgePreview else {
      Issue.record("Expected pending edge preview after begin")
      return
    }
    let anchor = viewModel.portAnchor(
      for: PolicyCanvasPortEndpoint(
        nodeID: "source",
        portID: "output-event",
        kind: .output
      )
    )
    #expect(preview.source.nodeID == "source")
    #expect(preview.source.portID == "output-event")
    #expect(preview.sourceAnchor == anchor)
    #expect(preview.cursor == anchor)
  }

  @Test("begin with unknown port is a no-op")
  func beginIgnoresUnknownPort() {
    let viewModel = makeCanvas()
    viewModel.beginPendingEdge(sourceNodeID: "source", sourcePortID: "nope")
    #expect(viewModel.pendingEdgePreview == nil)
  }

  @Test("begin with input port is a no-op (drag only starts from outputs)")
  func beginIgnoresInputPort() {
    let viewModel = makeCanvas()
    viewModel.beginPendingEdge(sourceNodeID: "sink", sourcePortID: "input-event")
    #expect(viewModel.pendingEdgePreview == nil)
  }

  @Test("update cursor tracks the live drag position")
  func updateCursorTracksDrag() {
    let viewModel = makeCanvas()
    viewModel.beginPendingEdge(sourceNodeID: "source", sourcePortID: "output-event")

    viewModel.updatePendingEdgeCursor(CGPoint(x: 500, y: 320))
    #expect(viewModel.pendingEdgePreview?.cursor == CGPoint(x: 500, y: 320))

    viewModel.updatePendingEdgeCursor(CGPoint(x: 540, y: 360))
    #expect(viewModel.pendingEdgePreview?.cursor == CGPoint(x: 540, y: 360))
  }

  @Test("update cursor with no active preview is a no-op")
  func updateCursorWithoutPreviewIsNoOp() {
    let viewModel = makeCanvas()
    viewModel.updatePendingEdgeCursor(CGPoint(x: 100, y: 100))
    #expect(viewModel.pendingEdgePreview == nil)
  }

  @Test("clearPendingEdge cancels the preview and the highlighted input")
  func clearCancelsPreviewAndHighlight() {
    let viewModel = makeCanvas()
    viewModel.beginPendingEdge(sourceNodeID: "source", sourcePortID: "output-event")
    viewModel.setInputTargeted(true, nodeID: "sink", portID: "input-event")
    #expect(viewModel.pendingEdgePreview != nil)
    #expect(viewModel.highlightedInput != nil)

    viewModel.clearPendingEdge()

    #expect(viewModel.pendingEdgePreview == nil)
    #expect(viewModel.highlightedInput == nil)
  }

  @Test("successful drop commits edge and clears preview")
  func successfulDropClearsPreview() {
    let viewModel = makeCanvas()
    let payload = viewModel.portDragPayload(nodeID: "source", portID: "output-event")
    viewModel.beginPendingEdge(sourceNodeID: "source", sourcePortID: "output-event")
    viewModel.updatePendingEdgeCursor(CGPoint(x: 500, y: 320))

    let connected = viewModel.connectDroppedPortPayloads(
      [payload],
      targetNodeID: "sink",
      targetPortID: "input-event"
    )

    #expect(connected)
    #expect(viewModel.pendingEdgePreview == nil)
    #expect(viewModel.highlightedInput == nil)
    #expect(viewModel.edges.contains { $0.source.nodeID == "source" && $0.target.nodeID == "sink" })
  }

  @Test("self-drop rejects the edge and clears preview")
  func selfDropClearsPreview() {
    let viewModel = makeCanvas()
    let payload = viewModel.portDragPayload(nodeID: "source", portID: "output-event")
    viewModel.beginPendingEdge(sourceNodeID: "source", sourcePortID: "output-event")

    let connected = viewModel.connectDroppedPortPayloads(
      [payload],
      targetNodeID: "source",
      targetPortID: "input-event"
    )

    #expect(!connected)
    #expect(viewModel.pendingEdgePreview == nil)
  }

  @Test("clearPendingEdge is idempotent")
  func clearIsIdempotent() {
    let viewModel = makeCanvas()
    viewModel.clearPendingEdge()
    viewModel.clearPendingEdge()
    #expect(viewModel.pendingEdgePreview == nil)
  }

  @Test("hasPendingEdge mirrors pendingEdgePreview across lifecycle")
  func hasPendingEdgeMirrorsLifecycle() {
    let viewModel = makeCanvas()
    #expect(viewModel.pendingEdgePreview == nil)
    #expect(viewModel.hasPendingEdge == false)

    viewModel.beginPendingEdge(sourceNodeID: "source", sourcePortID: "output-event")
    #expect(viewModel.pendingEdgePreview != nil)
    #expect(viewModel.hasPendingEdge == true)

    // Cursor updates must not flip the presence bit — only views that
    // subscribe to `pendingEdgePreview` (the rubber-band layer) re-evaluate.
    viewModel.updatePendingEdgeCursor(CGPoint(x: 540, y: 360))
    #expect(viewModel.hasPendingEdge == true)

    viewModel.clearPendingEdge()
    #expect(viewModel.pendingEdgePreview == nil)
    #expect(viewModel.hasPendingEdge == false)
  }

  @Test("clearTransientGestureState clears every transient affordance")
  func clearTransientGestureStateClearsAll() {
    let viewModel = makeCanvas()
    viewModel.beginPendingEdge(sourceNodeID: "source", sourcePortID: "output-event")
    viewModel.setInputTargeted(true, nodeID: "sink", portID: "input-event")
    viewModel.setGroupDropTargeted(true, groupID: "group-a")

    viewModel.clearTransientGestureState()

    #expect(viewModel.pendingEdgePreview == nil)
    #expect(viewModel.hasPendingEdge == false)
    #expect(viewModel.highlightedInput == nil)
    #expect(viewModel.highlightedGroupID == nil)
  }

  @Test("clearTransientGestureState is idempotent")
  func clearTransientGestureStateIsIdempotent() {
    let viewModel = makeCanvas()
    viewModel.clearTransientGestureState()
    viewModel.clearTransientGestureState()
    #expect(viewModel.pendingEdgePreview == nil)
    #expect(viewModel.hasPendingEdge == false)
    #expect(viewModel.highlightedInput == nil)
    #expect(viewModel.highlightedGroupID == nil)
  }

  // MARK: - Helpers

  private func makeCanvas() -> PolicyCanvasViewModel {
    let source = PolicyCanvasNode(
      id: "source",
      title: "Source",
      kind: .source,
      position: CGPoint(x: 120, y: 140)
    )
    let sink = PolicyCanvasNode(
      id: "sink",
      title: "Sink",
      kind: .condition,
      position: CGPoint(x: 420, y: 240)
    )
    return PolicyCanvasViewModel(
      nodes: [source, sink],
      groups: [],
      edges: [],
      selection: nil,
      zoom: 1
    )
  }
}
