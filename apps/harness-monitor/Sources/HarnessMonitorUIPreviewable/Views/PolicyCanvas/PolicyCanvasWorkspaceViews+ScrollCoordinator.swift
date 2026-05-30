import AppKit
import HarnessMonitorKit
import SwiftUI

struct PolicyCanvasViewportScrollRequest: Equatable {
  let id: UInt64
  let point: CGPoint
  let consumesViewportCenteringRequest: Bool
}

struct PolicyCanvasViewportObservedState: Equatable, Sendable {
  let visibleContentRect: CGRect
  let zoom: CGFloat
}

struct PolicyCanvasViewportHostedSnapshot {
  let viewModel: PolicyCanvasViewModel
  let focusedComponent: AccessibilityFocusState<PolicyCanvasSelection?>.Binding
  let edges: [PolicyCanvasEdge]
  let routes: [String: PolicyCanvasEdgeRoute]
  let labelPositions: [String: CGPoint]
  let accessibilityLabelsByEdgeID: [String: String]
  let accessibilityNodeEntries: [PolicyCanvasAccessibilityNodeEntry]
  let accessibilityEdgeEntries: [PolicyCanvasAccessibilityEdgeEntry]
  let nodeAccessibilityValuesByID: [String: String]
  let connectTargetsByNodeID: [String: [PolicyCanvasAccessibilityConnectTarget]]
  let nodeValidationIssueMessagesByID: [String: String]
  let portVisibility: PolicyCanvasPortVisibilityMap
  let portMarkerLayout: PolicyCanvasPortMarkerLayout
  /// Cheap counts+checksum fingerprint of the route worker output the
  /// render-relevant fields above were destructured from. Lets
  /// `PolicyCanvasViewportHostedState.update(snapshot:)` decide whether the
  /// content tree needs to re-evaluate without diffing the route, label, and
  /// port dictionaries on every parent re-render.
  let routeSignature: PolicyCanvasRouteWorkerOutputSignature
  let contentSize: CGSize
  let resolvedCanvasColorScheme: ColorScheme?
  let showSimulationOverlay: Bool
  let openEditor: @MainActor (PolicyCanvasEditSheet) -> Void
  let requestKeyboardFocus: @MainActor () -> Void

  /// Everything the hosted content tree renders from, minus the view-model
  /// reference (observed directly by the child layers) and the stable
  /// closures and focus binding. Two snapshots that share this signature
  /// would draw identically, so a viewport scroll that only moves the clip
  /// view must not republish the `@Observable` snapshot.
  var renderSignature: PolicyCanvasViewportHostedRenderSignature {
    PolicyCanvasViewportHostedRenderSignature(
      routeSignature: routeSignature,
      edges: edges,
      nodeValidationIssueMessagesByID: nodeValidationIssueMessagesByID,
      contentSize: contentSize,
      resolvedCanvasColorScheme: resolvedCanvasColorScheme,
      showSimulationOverlay: showSimulationOverlay
    )
  }
}

/// Equatable change-detector for `PolicyCanvasViewportHostedSnapshot`. Bundles
/// only value-semantic render inputs so equality means "the canvas draws the
/// same"; the route fingerprint stands in for the routes, labels, ports, and
/// accessibility maps that all derive from one route worker pass.
struct PolicyCanvasViewportHostedRenderSignature: Equatable {
  let routeSignature: PolicyCanvasRouteWorkerOutputSignature
  let edges: [PolicyCanvasEdge]
  let nodeValidationIssueMessagesByID: [String: String]
  let contentSize: CGSize
  let resolvedCanvasColorScheme: ColorScheme?
  let showSimulationOverlay: Bool
}

@Observable
@MainActor
final class PolicyCanvasViewportHostedState {
  var snapshot: PolicyCanvasViewportHostedSnapshot
  var workspaceLayout: PolicyCanvasAdaptiveWorkspaceLayout
  // Kept outside the render-gated snapshot so it always reflects the live
  // sceneFocusEnabled value from the parent view, even when renderSignature
  // is unchanged (same canvas content, different route visibility).
  private(set) var requestKeyboardFocus: (@MainActor () -> Void)?

  init(snapshot: PolicyCanvasViewportHostedSnapshot) {
    self.snapshot = snapshot
    self.requestKeyboardFocus = snapshot.requestKeyboardFocus
    workspaceLayout = policyCanvasInitialAdaptiveWorkspaceLayout(
      contentSize: snapshot.contentSize,
      viewportSize: .zero
    )
  }

  func update(snapshot: PolicyCanvasViewportHostedSnapshot) {
    // Always refresh the focus closure so a sceneFocusEnabled flip (false→true
    // when the user navigates to the canvas tab) is not silently swallowed by
    // the renderSignature guard below.
    requestKeyboardFocus = snapshot.requestKeyboardFocus
    // Defense-in-depth for the scroll hot path. A pure pan re-runs the parent
    // viewport body, which rebuilds this snapshot with fresh closures every
    // time, so `NSViewRepresentable.updateNSView` always calls back here. If
    // nothing the canvas renders changed, skip the assignment: republishing an
    // `@Observable` property notifies observers regardless of value equality,
    // and that notification would re-evaluate the entire hosted content tree
    // (grid, every node, every edge, every label) once per scroll frame.
    guard snapshot.renderSignature != self.snapshot.renderSignature else {
      return
    }
    self.snapshot = snapshot
  }

  func update(workspaceLayout: PolicyCanvasAdaptiveWorkspaceLayout) {
    self.workspaceLayout = workspaceLayout
  }
}

struct PolicyCanvasViewportHostedRoot: View {
  let state: PolicyCanvasViewportHostedState

  var body: some View {
    let snapshot = state.snapshot
    let workspaceLayout = state.workspaceLayout
    ZStack(alignment: .topLeading) {
      PolicyCanvasBackgroundSurface()
        .policyCanvasDocumentLayer(size: snapshot.contentSize)
        .offset(x: workspaceLayout.contentOrigin.x, y: workspaceLayout.contentOrigin.y)

      ZStack(alignment: .topLeading) {
        PolicyCanvasGroupLayer(
          viewModel: snapshot.viewModel,
          focusedComponent: snapshot.focusedComponent,
          openEditor: snapshot.openEditor
        )
        .policyCanvasDocumentLayer(size: snapshot.contentSize)
        PolicyCanvasEdgeLayer(
          viewModel: snapshot.viewModel,
          focusedComponent: snapshot.focusedComponent,
          edges: snapshot.edges,
          routes: snapshot.routes,
          labelPositions: snapshot.labelPositions,
          accessibilityLabelsByEdgeID: snapshot.accessibilityLabelsByEdgeID,
          openEditor: snapshot.openEditor
        )
        .policyCanvasDocumentLayer(size: snapshot.contentSize)
        PolicyCanvasMarqueeSelectionLayer(
          marqueeSelection: snapshot.viewModel.marqueeSelection
        )
        .policyCanvasDocumentLayer(size: snapshot.contentSize)
        PolicyCanvasRubberBandLayer(viewModel: snapshot.viewModel)
          .policyCanvasDocumentLayer(size: snapshot.contentSize)
        PolicyCanvasNodeLayer(
          viewModel: snapshot.viewModel,
          focusedComponent: snapshot.focusedComponent,
          nodeAccessibilityValuesByID: snapshot.nodeAccessibilityValuesByID,
          connectTargetsByNodeID: snapshot.connectTargetsByNodeID,
          nodeValidationIssueMessagesByID: snapshot.nodeValidationIssueMessagesByID,
          portVisibility: snapshot.portVisibility,
          portMarkerLayout: snapshot.portMarkerLayout,
          openEditor: snapshot.openEditor
        )
        .policyCanvasDocumentLayer(size: snapshot.contentSize)
        if snapshot.showSimulationOverlay {
          PolicyCanvasSimulationLayer(viewModel: snapshot.viewModel)
            .policyCanvasDocumentLayer(size: snapshot.contentSize)
        }
        PolicyCanvasEdgeLabelLayer(
          viewModel: snapshot.viewModel,
          focusedComponent: snapshot.focusedComponent,
          edges: snapshot.edges,
          routes: snapshot.routes,
          labelPositions: snapshot.labelPositions
        )
        .policyCanvasDocumentLayer(size: snapshot.contentSize)
      }
      .policyCanvasDocumentLayer(size: snapshot.contentSize)
      .offset(x: workspaceLayout.contentOrigin.x, y: workspaceLayout.contentOrigin.y)
    }
    .contentShape(Rectangle())
    .onTapGesture {
      snapshot.viewModel.select(nil)
    }
    .frame(
      width: workspaceLayout.workspaceSize.width,
      height: workspaceLayout.workspaceSize.height,
      alignment: .topLeading
    )
    .transformEnvironment(\.colorScheme) { current in
      if let resolvedCanvasColorScheme = snapshot.resolvedCanvasColorScheme {
        current = resolvedCanvasColorScheme
      }
    }
    .coordinateSpace(.named(PolicyCanvasCoordinateSpaces.canvas))
    .contentShape(Rectangle())
    .dropDestination(for: String.self) { payloads, location in
      snapshot.viewModel.dropPalettePayloads(
        payloads,
        at: workspaceLayout.contentPoint(forWorkspacePoint: location)
      )
    }
    .accessibilityElement(children: .contain)
    .accessibilityRotor("Nodes") {
      ForEach(snapshot.accessibilityNodeEntries) { entry in
        AccessibilityRotorEntry(entry.label, id: entry.id)
      }
    }
    .accessibilityRotor("Edges") {
      ForEach(snapshot.accessibilityEdgeEntries) { entry in
        AccessibilityRotorEntry(entry.label, id: entry.id)
      }
    }
  }
}

extension View {
  fileprivate func policyCanvasDocumentLayer(size: CGSize) -> some View {
    frame(width: size.width, height: size.height, alignment: .topLeading)
  }
}

@MainActor
final class PolicyCanvasNativeDocumentView: NSView {
  enum PointerTarget: Equatable {
    case node(String)
    case group(String)

    var traceDescription: String {
      switch self {
      case .node(let id):
        "node:\(id)"
      case .group(let id):
        "group:\(id)"
      }
    }
  }

  struct PointerDrag {
    let target: PointerTarget
    let startPoint: CGPoint
    var didBeginDrag = false
  }

  struct MarqueePointerDrag {
    let startPoint: CGPoint
    let mode: PolicyCanvasMarqueeSelectionMode
    let baselineSelections: Set<PolicyCanvasSelection>
    var didBeginDrag = false
  }

  override var isFlipped: Bool { true }

  private(set) var hostedState: PolicyCanvasViewportHostedState
  let hostingView: PolicyCanvasNativeHostingView
  var pointerDrag: PointerDrag?
  var marqueePointerDrag: MarqueePointerDrag?
  var targetedInput: PolicyCanvasPortEndpoint?

  init(state: PolicyCanvasViewportHostedState) {
    hostedState = state
    hostingView = PolicyCanvasNativeHostingView(
      rootView: PolicyCanvasViewportHostedRoot(state: state))
    super.init(frame: .zero)
    hostingView.documentInteractionDelegate = self
    addSubview(hostingView)
    registerForDraggedTypes([.string])
    hostingView.registerForDraggedTypes([.string])
  }

  override init(frame frameRect: NSRect) {
    fatalError("init(frame:) has not been implemented")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    hostingView.frame = bounds
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard bounds.contains(point) else {
      return nil
    }
    if pointerTarget(at: point) != nil {
      return self
    }
    return super.hitTest(point)
  }

  override func mouseDown(with event: NSEvent) {
    if routeMouseDown(event) {
      return
    }
    super.mouseDown(with: event)
  }

  override func mouseDragged(with event: NSEvent) {
    if routeMouseDragged(event) {
      return
    }
    super.mouseDragged(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    if routeMouseUp(event) {
      return
    }
    super.mouseUp(with: event)
  }

  var rootViewState: PolicyCanvasViewportHostedState {
    hostingView.rootView.state
  }

  func rebind(state: PolicyCanvasViewportHostedState) {
    guard hostedState !== state else {
      return
    }
    hostedState = state
    hostingView.rootView = PolicyCanvasViewportHostedRoot(state: state)
    needsLayout = true
  }

  func updateSize(_ size: CGSize) {
    frame = CGRect(origin: .zero, size: size)
    hostingView.frame = bounds
    needsLayout = true
  }
}
