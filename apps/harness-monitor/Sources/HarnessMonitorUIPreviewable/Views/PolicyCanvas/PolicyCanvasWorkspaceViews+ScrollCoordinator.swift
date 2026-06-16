import AppKit
import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

struct PolicyCanvasViewportScrollRequest: Equatable {
  let id: UInt64
  let target: PolicyCanvasViewportScrollTarget
  let viewportCenteringGenerationToConsume: UInt64?
}

enum PolicyCanvasViewportScrollTarget: Equatable {
  case contentOrigin(CGPoint)
  case centeredDocumentAnchor(CGPoint)

  func contentOrigin(forVisibleContentSize visibleContentSize: CGSize) -> CGPoint {
    switch self {
    case .contentOrigin(let point):
      return point
    case .centeredDocumentAnchor(let anchorPoint):
      return CGPoint(
        x: anchorPoint.x - (visibleContentSize.width / 2),
        y: anchorPoint.y - (visibleContentSize.height / 2)
      )
    }
  }
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
  var observationStore: PolicyCanvasViewportObservationStore
  var viewportIdentity: String?
  // Kept outside the render-gated snapshot so it always reflects the live
  // sceneFocusEnabled value from the parent view, even when renderSignature
  // is unchanged (same canvas content, different route visibility).
  private(set) var requestKeyboardFocus: (@MainActor () -> Void)?

  init(
    snapshot: PolicyCanvasViewportHostedSnapshot,
    observationStore: PolicyCanvasViewportObservationStore = PolicyCanvasViewportObservationStore(),
    viewportIdentity: String? = nil
  ) {
    self.snapshot = snapshot
    self.observationStore = observationStore
    self.viewportIdentity = viewportIdentity
    self.requestKeyboardFocus = snapshot.requestKeyboardFocus
    workspaceLayout = policyCanvasInitialAdaptiveWorkspaceLayout(
      contentSize: snapshot.contentSize,
      viewportSize: .zero
    )
  }

  func update(
    snapshot: PolicyCanvasViewportHostedSnapshot,
    observationStore: PolicyCanvasViewportObservationStore,
    viewportIdentity: String?
  ) {
    // Always refresh the focus closure so a sceneFocusEnabled flip (false→true
    // when the user navigates to the canvas tab) is not silently swallowed by
    // the renderSignature guard below.
    requestKeyboardFocus = snapshot.requestKeyboardFocus
    self.observationStore = observationStore
    self.viewportIdentity = viewportIdentity
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

  func update(snapshot: PolicyCanvasViewportHostedSnapshot) {
    update(
      snapshot: snapshot,
      observationStore: observationStore,
      viewportIdentity: viewportIdentity
    )
  }

  func update(workspaceLayout: PolicyCanvasAdaptiveWorkspaceLayout) {
    guard workspaceLayout != self.workspaceLayout else {
      return
    }
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
        .frame(
          width: workspaceLayout.workspaceSize.width,
          height: workspaceLayout.workspaceSize.height,
          alignment: .topLeading
        )
        .contentShape(Rectangle())
        .onTapGesture {
          snapshot.viewModel.select(nil)
        }
      ZStack(alignment: .topLeading) {
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
            contentSize: snapshot.contentSize,
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
          // Mounted unconditionally and reading the report live in their own
          // bodies, so a variant switch or overlay toggle re-renders them. A
          // parent `if let` here would capture a stale report inside the hosted
          // canvas. Both draw nothing when the lab overlay is off.
          PolicyCanvasQualityOverlayLayer(viewModel: snapshot.viewModel)
            .policyCanvasDocumentLayer(size: snapshot.contentSize)
          PolicyCanvasQualityHoverLayer(viewModel: snapshot.viewModel)
            .policyCanvasDocumentLayer(size: snapshot.contentSize)
        }
        .policyCanvasDocumentLayer(size: snapshot.contentSize)
      }
      .policyCanvasDocumentLayer(size: snapshot.contentSize)
      .offset(x: workspaceLayout.contentOrigin.x, y: workspaceLayout.contentOrigin.y)
    }
    .policyCanvasResolvedThemeScope(snapshot.resolvedCanvasColorScheme)
    .frame(
      width: workspaceLayout.workspaceSize.width,
      height: workspaceLayout.workspaceSize.height,
      alignment: .topLeading
    )
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
    case edge(String)

    var traceDescription: String {
      switch self {
      case .node(let id):
        "node:\(id)"
      case .group(let id):
        "group:\(id)"
      case .edge(let id):
        "edge:\(id)"
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

  nonisolated override var isFlipped: Bool { true }
  nonisolated override var isOpaque: Bool { true }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
  }

  override var fittingSize: NSSize {
    policyCanvasFixedFittingSize(for: frame.size, fallback: bounds.size)
  }

  private(set) var hostedState: PolicyCanvasViewportHostedState
  let hostingView: PolicyCanvasNativeHostingView
  var pointerDrag: PointerDrag?
  var marqueePointerDrag: MarqueePointerDrag?
  var targetedInput: PolicyCanvasPortEndpoint?

  // Lab quality-overlay hover tracking (see the +QualityHover extension). The
  // mark cache is rebuilt only when `qualityReportGeneration` changes, so each
  // pointer move filters a prebuilt array instead of rebuilding every mark.
  var qualityHoverCache: [PolicyCanvasQualityHoverMark] = []
  var qualityHoverCacheGeneration = -1
  var qualityHoverActiveIDs: [Int] = []

  init(state: PolicyCanvasViewportHostedState) {
    hostedState = state
    hostingView = PolicyCanvasNativeHostingView(
      rootView: PolicyCanvasViewportHostedRoot(state: state))
    super.init(frame: .zero)
    configureCanvasRenderingSurface()
    hostingView.documentInteractionDelegate = self
    addSubview(hostingView)
    registerForDraggedTypes(policyCanvasAcceptedTextPasteboardTypes)
    hostingView.registerForDraggedTypes(policyCanvasAcceptedTextPasteboardTypes)
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
    if hostingView.frame != bounds {
      hostingView.frame = bounds
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    configureCanvasRenderingSurface()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    configureCanvasRenderingSurface()
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    hitTestTarget(at: point, allowsSwiftUIPortHitTesting: shouldResolveInteractiveMouseHitTest)
  }

  func hitTestTarget(
    at point: NSPoint,
    allowsSwiftUIPortHitTesting: Bool
  ) -> NSView? {
    guard bounds.contains(point) else {
      return nil
    }
    guard allowsSwiftUIPortHitTesting else {
      return self
    }
    let contentPoint = contentPoint(fromWorkspacePoint: point)
    if case .port = hostedState.snapshot.viewModel.canvasPointerHitTarget(
      at: contentPoint,
      portVisibility: hostedState.snapshot.portVisibility,
      portMarkerLayout: hostedState.snapshot.portMarkerLayout
    ) {
      return hostingView
    }
    return self
  }

  private var shouldResolveInteractiveMouseHitTest: Bool {
    switch NSApp.currentEvent?.type {
    case .leftMouseDown, .leftMouseDragged, .rightMouseDown, .otherMouseDown:
      true
    default:
      false
    }
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

  override func menu(for event: NSEvent) -> NSMenu? {
    let point = convert(event.locationInWindow, from: nil)
    guard let target = pointerTarget(at: point) else {
      return super.menu(for: event)
    }
    return nativeContextMenu(for: target)
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    routeDraggingEntered(sender) ?? super.draggingEntered(sender)
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    routeDraggingUpdated(sender) ?? super.draggingUpdated(sender)
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    routeDraggingExited(sender)
    super.draggingExited(sender)
  }

  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    routePrepareForDragOperation(sender) || super.prepareForDragOperation(sender)
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    routePerformDragOperation(sender) || super.performDragOperation(sender)
  }

  var rootViewState: PolicyCanvasViewportHostedState {
    hostingView.rootView.state
  }

  func rebind(state: PolicyCanvasViewportHostedState) {
    guard hostedState !== state else {
      return
    }
    hostedState = state
    hostingView.replaceRootView(PolicyCanvasViewportHostedRoot(state: state))
    needsLayout = true
  }

  func updateSize(_ size: CGSize) {
    guard frame.size != size || hostingView.frame.size != size else {
      return
    }
    hostingView.markHostedLayoutRequired()
    frame = CGRect(origin: .zero, size: size)
    if hostingView.frame != bounds {
      hostingView.frame = bounds
    }
    if !needsLayout {
      needsLayout = true
    }
  }

  private func configureCanvasRenderingSurface() {
    policyCanvasApplyOpaqueViewportBacking(to: self)
    hostingView.configureCanvasRenderingSurface()
  }
}
