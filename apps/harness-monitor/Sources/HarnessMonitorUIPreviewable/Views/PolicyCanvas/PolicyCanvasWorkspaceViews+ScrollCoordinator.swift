import AppKit
import SwiftUI

struct PolicyCanvasViewportScrollRequest: Equatable {
  let id: UInt64
  let point: CGPoint
  let consumesViewportCenteringRequest: Bool
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
  let contentSize: CGSize
  let showSimulationOverlay: Bool
  let openEditor: @MainActor (PolicyCanvasEditSheet) -> Void
}

@Observable
@MainActor
final class PolicyCanvasViewportHostedState {
  var snapshot: PolicyCanvasViewportHostedSnapshot

  init(snapshot: PolicyCanvasViewportHostedSnapshot) {
    self.snapshot = snapshot
  }

  func update(snapshot: PolicyCanvasViewportHostedSnapshot) {
    self.snapshot = snapshot
  }
}

struct PolicyCanvasViewportHostedRoot: View {
  let state: PolicyCanvasViewportHostedState

  var body: some View {
    let snapshot = state.snapshot
    ZStack(alignment: .topLeading) {
      PolicyCanvasDottedGrid(spacing: PolicyCanvasLayout.gridSize)
        .contentShape(Rectangle())
        .onTapGesture {
          snapshot.viewModel.select(nil)
        }

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
    }
    .frame(
      width: snapshot.contentSize.width,
      height: snapshot.contentSize.height,
      alignment: .topLeading
    )
    .coordinateSpace(.named(PolicyCanvasCoordinateSpaces.canvas))
    .contentShape(Rectangle())
    .dropDestination(for: String.self) { payloads, location in
      snapshot.viewModel.dropPalettePayloads(payloads, at: location)
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

private extension View {
  func policyCanvasDocumentLayer(size: CGSize) -> some View {
    frame(width: size.width, height: size.height, alignment: .topLeading)
  }
}

struct PolicyCanvasViewportNativeHost: NSViewRepresentable {
  var snapshot: PolicyCanvasViewportHostedSnapshot
  var zoom: CGFloat
  var isActive = true
  var isEmpty = false
  var request: PolicyCanvasViewportScrollRequest?
  var onFulfillRequest: @MainActor (PolicyCanvasViewportScrollRequest, Bool) -> Void
  var onZoomChange: @MainActor (CGFloat) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(snapshot: snapshot)
  }

  func makeNSView(context: Context) -> PolicyCanvasNativeScrollView {
    let scrollView = PolicyCanvasNativeScrollView()
    scrollView.ensureDocumentRoot(
      state: context.coordinator.hostedState,
      size: snapshot.contentSize
    )
    scrollView.magnificationDidChange = { [weak coordinator = context.coordinator] zoom in
      coordinator?.handleViewportZoomChange(zoom)
    }
    return scrollView
  }

  func updateNSView(_ scrollView: PolicyCanvasNativeScrollView, context: Context) {
    context.coordinator.onFulfillRequest = onFulfillRequest
    context.coordinator.onZoomChange = onZoomChange
    context.coordinator.hostedState.update(snapshot: snapshot)
    scrollView.magnificationDidChange = { [weak coordinator = context.coordinator] zoom in
      coordinator?.handleViewportZoomChange(zoom)
    }
    scrollView.setInteractionEnabled(isActive && !isEmpty)
    scrollView.ensureDocumentRoot(
      state: context.coordinator.hostedState,
      size: snapshot.contentSize
    )
    context.coordinator.applyModelZoomIfNeeded(zoom, to: scrollView)
    context.coordinator.updateRequest(request)
    context.coordinator.applyPendingRequest(on: scrollView)
  }

  @MainActor
  final class Coordinator {
    let hostedState: PolicyCanvasViewportHostedState
    var onFulfillRequest: ((PolicyCanvasViewportScrollRequest, Bool) -> Void)?
    var onZoomChange: ((CGFloat) -> Void)?
    private var request: PolicyCanvasViewportScrollRequest?
    private var appliedRequest: PolicyCanvasViewportScrollRequest?
    private var isApplyingModelZoom = false
    private var isRetryScheduled = false

    init(snapshot: PolicyCanvasViewportHostedSnapshot) {
      hostedState = PolicyCanvasViewportHostedState(snapshot: snapshot)
    }

    func updateRequest(_ request: PolicyCanvasViewportScrollRequest?) {
      guard self.request != request else {
        return
      }
      self.request = request
    }

    func handleViewportZoomChange(_ zoom: CGFloat) {
      guard !isApplyingModelZoom else {
        return
      }
      onZoomChange?(zoom)
    }

    func applyModelZoomIfNeeded(
      _ zoom: CGFloat,
      to scrollView: PolicyCanvasNativeScrollView
    ) {
      guard abs(scrollView.magnification - zoom) > 0.001 else {
        return
      }
      isApplyingModelZoom = true
      scrollView.setMagnification(zoom, centeredAt: scrollView.visibleDocumentCenter)
      isApplyingModelZoom = false
    }

    func applyPendingRequest(on scrollView: PolicyCanvasNativeScrollView) {
      guard let request, appliedRequest != request else {
        return
      }
      switch scrollView.applyScrollRequest(request.point) {
      case .applied(let didScroll):
        onFulfillRequest?(request, didScroll)
        appliedRequest = request
        isRetryScheduled = false
      case .needsRetry:
        scheduleRetry(on: scrollView, request: request)
      }
    }

    private func scheduleRetry(
      on scrollView: PolicyCanvasNativeScrollView,
      request: PolicyCanvasViewportScrollRequest
    ) {
      guard !isRetryScheduled else {
        return
      }
      isRetryScheduled = true
      DispatchQueue.main.async { [weak self, weak scrollView] in
        guard let self else {
          return
        }
        self.isRetryScheduled = false
        guard let scrollView, self.request == request else {
          return
        }
        self.applyPendingRequest(on: scrollView)
      }
    }
  }
}

@MainActor
final class PolicyCanvasNativeScrollView: NSScrollView {
  enum ScrollRequestResult: Equatable {
    case applied(Bool)
    case needsRetry
  }

  var magnificationDidChange: ((CGFloat) -> Void)?

  private let centeringClipView = PolicyCanvasCenteringClipView()
  private var interactionEnabled = true

  init() {
    super.init(frame: .zero)
    drawsBackground = false
    borderType = .noBorder
    scrollerStyle = .overlay
    hasHorizontalScroller = true
    hasVerticalScroller = true
    autohidesScrollers = false
    allowsMagnification = true
    minMagnification = PolicyCanvasLayout.minimumZoom
    maxMagnification = PolicyCanvasLayout.maximumZoom
    usesPredominantAxisScrolling = false
    contentView = centeringClipView
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  var visibleDocumentCenter: CGPoint {
    let visibleRect = documentVisibleRect
    return CGPoint(x: visibleRect.midX, y: visibleRect.midY)
  }

  func setInteractionEnabled(_ isEnabled: Bool) {
    interactionEnabled = isEnabled
    allowsMagnification = isEnabled
    hasHorizontalScroller = isEnabled
    hasVerticalScroller = isEnabled
    horizontalScrollElasticity = isEnabled ? .automatic : .none
    verticalScrollElasticity = isEnabled ? .automatic : .none
  }

  func ensureDocumentRoot(
    state: PolicyCanvasViewportHostedState,
    size: CGSize
  ) {
    let hostedDocumentView: PolicyCanvasNativeDocumentView
    if let existingDocumentView = documentView as? PolicyCanvasNativeDocumentView {
      hostedDocumentView = existingDocumentView
      hostedDocumentView.rebind(state: state)
    } else {
      let newDocumentView = PolicyCanvasNativeDocumentView(state: state)
      documentView = newDocumentView
      hostedDocumentView = newDocumentView
    }
    hostedDocumentView.updateSize(size)
    reflectScrolledClipView(contentView)
  }

  func setTestingDocumentContent<Content: View>(_ content: Content, size: CGSize) {
    let testingDocumentView = PolicyCanvasTestingDocumentView(rootView: content)
    documentView = testingDocumentView
    testingDocumentView.updateSize(size)
    reflectScrolledClipView(contentView)
  }

  func applyScrollRequest(_ point: CGPoint) -> ScrollRequestResult {
    guard contentView.bounds.width > 1, contentView.bounds.height > 1 else {
      return .needsRetry
    }
    let target = clampedDocumentPoint(point)
    let current = currentDocumentOffset
    let shouldScroll = abs(current.x - target.x) > 1 || abs(current.y - target.y) > 1
    if shouldScroll {
      contentView.scroll(to: target)
      reflectScrolledClipView(contentView)
    }
    return .applied(shouldScroll)
  }

  override func magnify(with event: NSEvent) {
    guard interactionEnabled else {
      return
    }
    super.magnify(with: event)
    magnificationDidChange?(magnification)
  }

  override func scrollWheel(with event: NSEvent) {
    usesPredominantAxisScrolling = false
    guard interactionEnabled else {
      return
    }
    if event.modifierFlags.contains(.command) {
      guard
        let deltaY = policyCanvasCommandScrollDeltaY(event: event),
        let targetZoom = policyCanvasCommandScrollTargetZoom(
          currentZoom: magnification,
          deltaY: deltaY
        ),
        let documentView
      else {
        return
      }
      let anchor = documentView.convert(event.locationInWindow, from: nil)
      setMagnification(targetZoom, centeredAt: anchor)
      magnificationDidChange?(magnification)
      return
    }
    super.scrollWheel(with: event)
  }

  private var currentDocumentOffset: CGPoint {
    let origin = documentVisibleRect.origin
    return CGPoint(x: max(0, origin.x), y: max(0, origin.y))
  }

  private func clampedDocumentPoint(_ point: CGPoint) -> CGPoint {
    let maxOffset = maxDocumentOffset
    return CGPoint(
      x: min(max(0, point.x), maxOffset.x),
      y: min(max(0, point.y), maxOffset.y)
    )
  }

  private var maxDocumentOffset: CGPoint {
    guard let documentView else {
      return .zero
    }
    return CGPoint(
      x: max(0, documentView.frame.width - contentView.bounds.width),
      y: max(0, documentView.frame.height - contentView.bounds.height)
    )
  }
}

final class PolicyCanvasCenteringClipView: NSClipView {
  override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
    var constrained = super.constrainBoundsRect(proposedBounds)
    guard let documentView else {
      return constrained
    }
    if documentView.frame.width < constrained.width {
      constrained.origin.x = -((constrained.width - documentView.frame.width) / 2)
    }
    if documentView.frame.height < constrained.height {
      constrained.origin.y = -((constrained.height - documentView.frame.height) / 2)
    }
    return constrained
  }
}

@MainActor
final class PolicyCanvasNativeDocumentView: NSView {
  private enum PointerTarget: Equatable {
    case node(String)
    case group(String)
  }

  private struct PointerDrag {
    let target: PointerTarget
    let startPoint: CGPoint
    var didBeginDrag = false
  }

  override var isFlipped: Bool { true }

  private(set) var hostedState: PolicyCanvasViewportHostedState
  private let hostingView: PolicyCanvasNativeHostingView
  private var pointerDrag: PointerDrag?
  private var targetedInput: PolicyCanvasPortEndpoint?

  init(state: PolicyCanvasViewportHostedState) {
    hostedState = state
    hostingView = PolicyCanvasNativeHostingView(rootView: PolicyCanvasViewportHostedRoot(state: state))
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

  func routeMouseDown(_ event: NSEvent) -> Bool {
    let point = convert(event.locationInWindow, from: nil)
    guard let target = pointerTarget(at: point) else {
      pointerDrag = nil
      return false
    }
    pointerDrag = PointerDrag(target: target, startPoint: point)
    select(target, extending: event.modifierFlags.contains(.shift))
    if event.clickCount >= 2 {
      openEditor(for: target)
    }
    return true
  }

  func routeMouseDragged(_ event: NSEvent) -> Bool {
    guard var drag = pointerDrag else {
      return false
    }
    let point = convert(event.locationInWindow, from: nil)
    let translation = CGSize(
      width: point.x - drag.startPoint.x,
      height: point.y - drag.startPoint.y
    )
    guard drag.didBeginDrag || hypot(translation.width, translation.height) >= 3 else {
      return true
    }
    drag.didBeginDrag = true
    pointerDrag = drag
    switch drag.target {
    case .node(let id):
      hostedState.snapshot.viewModel.dragNode(id, translation: translation)
    case .group(let id):
      hostedState.snapshot.viewModel.dragGroup(id, translation: translation)
    }
    return true
  }

  func routeMouseUp(_ event: NSEvent) -> Bool {
    guard let drag = pointerDrag else {
      return false
    }
    pointerDrag = nil
    guard drag.didBeginDrag else {
      return true
    }
    let point = convert(event.locationInWindow, from: nil)
    let translation = CGSize(
      width: point.x - drag.startPoint.x,
      height: point.y - drag.startPoint.y
    )
    switch drag.target {
    case .node(let id):
      hostedState.snapshot.viewModel.endNodeDrag(id, translation: translation)
    case .group(let id):
      hostedState.snapshot.viewModel.endGroupDrag(id, translation: translation)
    }
    return true
  }

  func routeDraggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation? {
    routeDraggingUpdated(sender)
  }

  func routeDraggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation? {
    let payloads = policyCanvasDraggingStrings(sender)
    guard !payloads.isEmpty else {
      clearNativeDropTarget()
      return nil
    }
    let point = convert(sender.draggingLocation, from: nil)
    let viewModel = hostedState.snapshot.viewModel
    if payloads.contains(where: { viewModel.parsePalettePayload($0) != nil })
      || payloads.contains(where: { viewModel.parseAutomationPalettePayload($0) != nil })
    {
      updatePaletteDropTarget(at: point)
      return .copy
    }
    if let input = viewModel.canvasInputPortHitTarget(
      at: point,
      portVisibility: hostedState.snapshot.portVisibility,
      portMarkerLayout: hostedState.snapshot.portMarkerLayout
    ),
      payloads.contains(where: { viewModel.parseOutputPortPayload($0) != nil })
    {
      updateInputDropTarget(input)
      return .link
    }
    clearNativeDropTarget()
    return nil
  }

  func routeDraggingExited(_: NSDraggingInfo?) {
    clearNativeDropTarget()
  }

  func routePrepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    routeDraggingUpdated(sender) != nil
  }

  func routePerformDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let payloads = policyCanvasDraggingStrings(sender)
    guard !payloads.isEmpty else {
      clearNativeDropTarget()
      return false
    }
    let point = convert(sender.draggingLocation, from: nil)
    let viewModel = hostedState.snapshot.viewModel
    defer { clearNativeDropTarget() }
    if payloads.contains(where: { viewModel.parsePalettePayload($0) != nil })
      || payloads.contains(where: { viewModel.parseAutomationPalettePayload($0) != nil })
    {
      if let groupID = groupID(at: point) {
        return viewModel.dropPalettePayloadsOnGroup(payloads, groupID: groupID, at: point)
      }
      return viewModel.dropPalettePayloads(payloads, at: point)
    }
    if let input = viewModel.canvasInputPortHitTarget(
      at: point,
      portVisibility: hostedState.snapshot.portVisibility,
      portMarkerLayout: hostedState.snapshot.portMarkerLayout
    ),
      payloads.contains(where: { viewModel.parseOutputPortPayload($0) != nil })
    {
      return viewModel.connectDroppedPortPayloads(
        payloads,
        targetNodeID: input.nodeID,
        targetPortID: input.portID,
        targetSide: input.side
      )
    }
    return false
  }

  private func pointerTarget(at point: CGPoint) -> PointerTarget? {
    switch hostedState.snapshot.viewModel.canvasHitTarget(
      at: point,
      portVisibility: hostedState.snapshot.portVisibility,
      portMarkerLayout: hostedState.snapshot.portMarkerLayout
    ) {
    case .node(let id):
      return .node(id)
    case .group(let id):
      return .group(id)
    case .port, nil:
      return nil
    }
  }

  private func select(_ target: PointerTarget, extending: Bool) {
    let selection: PolicyCanvasSelection
    switch target {
    case .node(let id):
      selection = .node(id)
    case .group(let id):
      selection = .group(id)
    }
    if extending {
      hostedState.snapshot.viewModel.extendSelection(selection)
    } else {
      hostedState.snapshot.viewModel.select(selection)
    }
  }

  private func openEditor(for target: PointerTarget) {
    switch target {
    case .node(let id):
      hostedState.snapshot.openEditor(.node(id))
    case .group(let id):
      hostedState.snapshot.openEditor(.group(id))
    }
  }

  private func updatePaletteDropTarget(at point: CGPoint) {
    if let groupID = groupID(at: point) {
      hostedState.snapshot.viewModel.setGroupDropTargeted(true, groupID: groupID)
    } else {
      hostedState.snapshot.viewModel.highlightedGroupID = nil
    }
    clearInputDropTarget()
  }

  private func groupID(at point: CGPoint) -> String? {
    hostedState.snapshot.viewModel.groups.reversed().first { group in
      group.frame.contains(point)
    }?.id
  }

  private func updateInputDropTarget(_ input: PolicyCanvasPortEndpoint) {
    guard targetedInput != input else {
      return
    }
    clearNativeDropTarget()
    targetedInput = input
    hostedState.snapshot.viewModel.setInputTargeted(
      true,
      nodeID: input.nodeID,
      portID: input.portID,
      side: input.side
    )
  }

  private func clearInputDropTarget() {
    guard let input = targetedInput else {
      return
    }
    targetedInput = nil
    hostedState.snapshot.viewModel.setInputTargeted(
      false,
      nodeID: input.nodeID,
      portID: input.portID,
      side: input.side
    )
  }

  private func clearNativeDropTarget() {
    clearInputDropTarget()
    hostedState.snapshot.viewModel.highlightedGroupID = nil
  }
}

@MainActor
final class PolicyCanvasNativeHostingView: NSHostingView<PolicyCanvasViewportHostedRoot> {
  weak var documentInteractionDelegate: PolicyCanvasNativeDocumentView?

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  override func mouseDown(with event: NSEvent) {
    if documentInteractionDelegate?.routeMouseDown(event) == true {
      return
    }
    super.mouseDown(with: event)
  }

  override func mouseDragged(with event: NSEvent) {
    if documentInteractionDelegate?.routeMouseDragged(event) == true {
      return
    }
    super.mouseDragged(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    if documentInteractionDelegate?.routeMouseUp(event) == true {
      return
    }
    super.mouseUp(with: event)
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    documentInteractionDelegate?.routeDraggingEntered(sender) ?? super.draggingEntered(sender)
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    documentInteractionDelegate?.routeDraggingUpdated(sender) ?? super.draggingUpdated(sender)
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    documentInteractionDelegate?.routeDraggingExited(sender)
    super.draggingExited(sender)
  }

  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    documentInteractionDelegate?.routePrepareForDragOperation(sender)
      ?? super.prepareForDragOperation(sender)
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    documentInteractionDelegate?.routePerformDragOperation(sender)
      ?? super.performDragOperation(sender)
  }
}

@MainActor
private func policyCanvasDraggingStrings(_ sender: NSDraggingInfo) -> [String] {
  if let strings = sender.draggingPasteboard.readObjects(
    forClasses: [NSString.self],
    options: nil
  ) as? [NSString],
    !strings.isEmpty
  {
    return strings.map(String.init)
  }
  guard let string = sender.draggingPasteboard.string(forType: .string) else {
    return []
  }
  return [string]
}

final class PolicyCanvasTestingDocumentView<Content: View>: NSView {
  override var isFlipped: Bool { true }

  private let hostingView: NSHostingView<Content>

  init(rootView: Content) {
    hostingView = NSHostingView(rootView: rootView)
    super.init(frame: .zero)
    addSubview(hostingView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    hostingView.frame = bounds
  }

  func updateSize(_ size: CGSize) {
    frame = CGRect(origin: .zero, size: size)
    hostingView.frame = bounds
    needsLayout = true
  }
}
