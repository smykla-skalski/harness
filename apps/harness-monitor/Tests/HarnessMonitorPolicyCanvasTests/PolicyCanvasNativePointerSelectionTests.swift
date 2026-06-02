import AppKit
import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

@Suite("Policy canvas native pointer marquee")
@MainActor
struct PolicyCanvasNativePointerSelectionTests {
  @Test("empty-space press arms marquee immediately")
  func emptySpacePressArmsMarqueeImmediately() throws {
    let viewModel = PolicyCanvasViewModel.sample()
    let host = try makeHost(viewModel: viewModel)

    defer {
      host.window.orderOut(nil)
      host.window.contentView = nil
    }

    let down = try mouseEvent(
      type: .leftMouseDown,
      contentPoint: CGPoint(x: 20, y: 20),
      host: host,
      timestamp: 0,
      eventNumber: 1
    )

    #expect(host.documentView.routeMouseDown(down))
    let marquee = try #require(viewModel.marqueeSelection)
    #expect(marquee.mode == .replace)
    #expect(marquee.anchor == CGPoint(x: 20, y: 20))
    #expect(marquee.current == CGPoint(x: 20, y: 20))
    #expect(marquee.rect == CGRect(x: 20, y: 20, width: 0, height: 0))
  }

  @Test("sub-threshold drag updates marquee before selection changes")
  func subThresholdDragUpdatesMarqueeBeforeSelectionChanges() throws {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.node("context-map"))
    let host = try makeHost(viewModel: viewModel)

    defer {
      host.window.orderOut(nil)
      host.window.contentView = nil
    }

    let down = try mouseEvent(
      type: .leftMouseDown,
      contentPoint: CGPoint(x: 20, y: 20),
      host: host,
      timestamp: 0,
      eventNumber: 10
    )
    let drag = try mouseEvent(
      type: .leftMouseDragged,
      contentPoint: CGPoint(x: 22, y: 22),
      host: host,
      timestamp: 1,
      eventNumber: 11
    )

    #expect(host.documentView.routeMouseDown(down))
    #expect(host.documentView.routeMouseDragged(drag))
    let marquee = try #require(viewModel.marqueeSelection)
    #expect(marquee.anchor == CGPoint(x: 20, y: 20))
    #expect(marquee.current == CGPoint(x: 22, y: 22))
    #expect(viewModel.selection == .node("context-map"))
    #expect(viewModel.allSelections == Set([.node("context-map")]))
  }

  @Test("empty-space click still clears selection")
  func emptySpaceClickStillClearsSelection() throws {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.node("risk-score"))
    let host = try makeHost(viewModel: viewModel)

    defer {
      host.window.orderOut(nil)
      host.window.contentView = nil
    }

    let down = try mouseEvent(
      type: .leftMouseDown,
      contentPoint: CGPoint(x: 20, y: 20),
      host: host,
      timestamp: 0,
      eventNumber: 20
    )
    let up = try mouseEvent(
      type: .leftMouseUp,
      contentPoint: CGPoint(x: 20, y: 20),
      host: host,
      timestamp: 1,
      eventNumber: 21
    )

    #expect(host.documentView.routeMouseDown(down))
    #expect(host.documentView.routeMouseUp(up))
    #expect(viewModel.selection == nil)
    #expect(viewModel.allSelections.isEmpty)
    #expect(viewModel.marqueeSelection == nil)
  }

  @Test("empty-space drag starts marquee and replaces selection")
  func emptySpaceDragStartsMarqueeAndReplacesSelection() throws {
    let viewModel = PolicyCanvasViewModel.sample()
    let host = try makeHost(viewModel: viewModel)

    defer {
      host.window.orderOut(nil)
      host.window.contentView = nil
    }

    let down = try mouseEvent(
      type: .leftMouseDown,
      contentPoint: CGPoint(x: 20, y: 20),
      host: host,
      timestamp: 0,
      eventNumber: 1
    )
    let drag = try mouseEvent(
      type: .leftMouseDragged,
      contentPoint: CGPoint(x: 500, y: 260),
      host: host,
      timestamp: 1,
      eventNumber: 2
    )
    let up = try mouseEvent(
      type: .leftMouseUp,
      contentPoint: CGPoint(x: 500, y: 260),
      host: host,
      timestamp: 2,
      eventNumber: 3
    )

    #expect(host.documentView.routeMouseDown(down))
    #expect(host.documentView.routeMouseDragged(drag))
    #expect(host.documentView.routeMouseUp(up))
    #expect(viewModel.selection == .node("risk-score"))
    #expect(viewModel.isSelected(.node("policy-source")))
    #expect(viewModel.isSelected(.group("group-intake")))
    #expect(viewModel.isSelected(.edge("edge-intake-risk")))
    #expect(!viewModel.isSelected(.node("context-map")))
    #expect(viewModel.marqueeSelection == nil)
  }

  @Test("shift-drag adds captured items without dropping the current primary")
  func shiftDragAddsCapturedItems() throws {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.node("risk-score"))
    viewModel.extendSelection(.group("group-evaluation"))
    let host = try makeHost(viewModel: viewModel)

    defer {
      host.window.orderOut(nil)
      host.window.contentView = nil
    }

    let down = try mouseEvent(
      type: .leftMouseDown,
      contentPoint: CGPoint(x: 20, y: 20),
      modifierFlags: [.shift],
      host: host,
      timestamp: 0,
      eventNumber: 4
    )
    let drag = try mouseEvent(
      type: .leftMouseDragged,
      contentPoint: CGPoint(x: 320, y: 260),
      modifierFlags: [.shift],
      host: host,
      timestamp: 1,
      eventNumber: 5
    )
    let up = try mouseEvent(
      type: .leftMouseUp,
      contentPoint: CGPoint(x: 320, y: 260),
      modifierFlags: [.shift],
      host: host,
      timestamp: 2,
      eventNumber: 6
    )

    #expect(host.documentView.routeMouseDown(down))
    #expect(host.documentView.routeMouseDragged(drag))
    #expect(host.documentView.routeMouseUp(up))
    #expect(viewModel.selection == .node("risk-score"))
    #expect(viewModel.isSelected(.group("group-evaluation")))
    #expect(viewModel.isSelected(.node("policy-source")))
    #expect(viewModel.isSelected(.group("group-intake")))
    #expect(viewModel.isSelected(.edge("edge-intake-risk")))
    #expect(!viewModel.isSelected(.node("context-map")))
    #expect(viewModel.marqueeSelection == nil)
  }

  private func makeHost(
    viewModel: PolicyCanvasViewModel = PolicyCanvasViewModel.sample()
  ) throws -> NativePointerHost {
    let focusedComponent = AccessibilityFocusState<PolicyCanvasSelection?>().projectedValue
    let snapshot = hostedSnapshot(viewModel: viewModel, focusedComponent: focusedComponent)
    let state = PolicyCanvasViewportHostedState(snapshot: snapshot)
    let scrollView = PolicyCanvasNativeScrollView()
    let frame = CGRect(x: 0, y: 0, width: 900, height: 700)
    scrollView.frame = frame

    let window = NSWindow(
      contentRect: frame,
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )

    window.contentView = scrollView
    scrollView.ensureDocumentRoot(state: state, size: snapshot.contentSize)
    window.layoutIfNeeded()
    scrollView.layoutSubtreeIfNeeded()

    let documentView = try #require(scrollView.documentView as? PolicyCanvasNativeDocumentView)
    return NativePointerHost(
      state: state,
      scrollView: scrollView,
      window: window,
      documentView: documentView
    )
  }

  private func mouseEvent(
    type: NSEvent.EventType,
    contentPoint: CGPoint,
    modifierFlags: NSEvent.ModifierFlags = [],
    host: NativePointerHost,
    timestamp: TimeInterval,
    eventNumber: Int
  ) throws -> NSEvent {
    let workspacePoint = CGPoint(
      x: host.state.workspaceLayout.contentOrigin.x + contentPoint.x,
      y: host.state.workspaceLayout.contentOrigin.y + contentPoint.y
    )
    return try #require(
      NSEvent.mouseEvent(
        with: type,
        location: host.documentView.convert(workspacePoint, to: nil),
        modifierFlags: modifierFlags,
        timestamp: timestamp,
        windowNumber: host.window.windowNumber,
        context: nil,
        eventNumber: eventNumber,
        clickCount: 1,
        pressure: type == .leftMouseUp ? 0 : 1
      )
    )
  }

  private func hostedSnapshot(
    viewModel: PolicyCanvasViewModel = PolicyCanvasViewModel.sample(),
    focusedComponent: AccessibilityFocusState<PolicyCanvasSelection?>.Binding
  ) -> PolicyCanvasViewportHostedSnapshot {
    let routeOutput = PolicyCanvasRouteWorkerOutput.fallback(
      for: PolicyCanvasRouteWorkerInput(
        nodes: viewModel.nodes,
        groups: viewModel.groups,
        edges: viewModel.edges,
        fontScale: 1
      )
    )
    var routes = routeOutput.routes
    routes["edge-intake-risk"] = PolicyCanvasEdgeRoute(
      points: [
        CGPoint(x: 210, y: 180),
        CGPoint(x: 310, y: 180),
      ],
      labelPosition: CGPoint(x: 260, y: 180)
    )
    return PolicyCanvasViewportHostedSnapshot(
      viewModel: viewModel,
      focusedComponent: focusedComponent,
      edges: viewModel.edges,
      routes: routes,
      labelPositions: routeOutput.labelPositions,
      accessibilityLabelsByEdgeID: routeOutput.accessibilityEdgeLabelsByID,
      accessibilityNodeEntries: routeOutput.accessibilityNodeEntries,
      accessibilityEdgeEntries: routeOutput.accessibilityEdgeEntries,
      nodeAccessibilityValuesByID: routeOutput.nodeAccessibilityValuesByID,
      connectTargetsByNodeID: routeOutput.connectTargetsByNodeID,
      nodeValidationIssueMessagesByID: [:],
      portVisibility: routeOutput.portVisibility,
      portMarkerLayout: routeOutput.portMarkerLayout,
      routeSignature: routeOutput.signature,
      contentSize: routeOutput.contentSize,
      resolvedCanvasColorScheme: nil,
      showSimulationOverlay: false,
      openEditor: { _ in },
      requestKeyboardFocus: {}
    )
  }
}

private struct NativePointerHost {
  let state: PolicyCanvasViewportHostedState
  let scrollView: PolicyCanvasNativeScrollView
  let window: NSWindow
  let documentView: PolicyCanvasNativeDocumentView
}
