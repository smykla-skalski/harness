import AppKit
import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

extension PolicyCanvasNativeDocumentView {
  func nativeContextMenu(for target: PointerTarget) -> NSMenu {
    let menu = NSMenu()
    let editItem = NSMenuItem(
      title: "Edit",
      action: #selector(editNativeContextMenuItem(_:)),
      keyEquivalent: ""
    )
    editItem.target = self
    editItem.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Edit")
    editItem.representedObject = PolicyCanvasNativeContextMenuTarget(target)
    menu.addItem(editItem)
    return menu
  }

  @objc
  func editNativeContextMenuItem(_ sender: NSMenuItem) {
    guard
      let contextTarget = sender.representedObject as? PolicyCanvasNativeContextMenuTarget
    else {
      return
    }
    select(contextTarget.target, extending: false)
    openEditor(for: contextTarget.target)
  }

  func routeMouseDown(_ event: NSEvent) -> Bool {
    let point = convert(event.locationInWindow, from: nil)
    let contentPoint = contentPoint(fromWorkspacePoint: point)
    recordNativeTrace(
      event: "mouse.down.route",
      point: point,
      details: ["click_count": String(event.clickCount)]
    )
    guard
      let hitTarget = hostedState.snapshot.viewModel.canvasHitTarget(
        at: contentPoint,
        portVisibility: hostedState.snapshot.portVisibility,
        portMarkerLayout: hostedState.snapshot.portMarkerLayout
      )
    else {
      recordNativeTrace(event: "mouse.down.miss", point: point)
      pointerDrag = nil
      hostedState.requestKeyboardFocus?()
      hostedState.snapshot.viewModel.marqueeSelection = PolicyCanvasMarqueeSelectionState(
        anchor: contentPoint,
        current: contentPoint,
        mode: event.modifierFlags.contains(.shift) ? .add : .replace
      )
      marqueePointerDrag = MarqueePointerDrag(
        startPoint: point,
        mode: event.modifierFlags.contains(.shift) ? .add : .replace,
        baselineSelections: hostedState.snapshot.viewModel.allSelections
      )
      return true
    }
    guard let target = pointerTarget(for: hitTarget) else {
      pointerDrag = nil
      marqueePointerDrag = nil
      return false
    }
    recordNativeTrace(
      event: "mouse.down.hit",
      point: point,
      details: ["target": target.traceDescription]
    )
    hostedState.requestKeyboardFocus?()
    marqueePointerDrag = nil
    pointerDrag = PointerDrag(target: target, startPoint: point)
    select(target, extending: event.modifierFlags.contains(.shift))
    if event.clickCount >= 2 {
      openEditor(for: target)
    }
    return true
  }

  func routeMouseDragged(_ event: NSEvent) -> Bool {
    if var marqueeDrag = marqueePointerDrag {
      let point = convert(event.locationInWindow, from: nil)
      let distance = hypot(
        point.x - marqueeDrag.startPoint.x,
        point.y - marqueeDrag.startPoint.y
      )

      let anchor = contentPoint(fromWorkspacePoint: marqueeDrag.startPoint)
      let current = contentPoint(fromWorkspacePoint: point)
      let marquee = PolicyCanvasMarqueeSelectionState(
        anchor: anchor,
        current: current,
        mode: marqueeDrag.mode
      )
      let viewModel = hostedState.snapshot.viewModel
      viewModel.marqueeSelection = marquee

      guard marqueeDrag.didBeginDrag || distance >= 3 else {
        return true
      }

      marqueeDrag.didBeginDrag = true
      marqueePointerDrag = marqueeDrag
      let captured = PolicyCanvasMarqueeSelectionHitResolver.capturedSelections(
        marqueeRect: marquee.rect,
        nodes: viewModel.nodes,
        groups: viewModel.groups,
        edges: viewModel.edges,
        routes: hostedState.snapshot.routes
      )

      switch marqueeDrag.mode {
      case .replace:
        viewModel.replaceSelections(with: captured)
      case .add:
        viewModel.replaceSelections(with: marqueeDrag.baselineSelections.union(captured))
      }

      return true
    }

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
    if let marqueeDrag = marqueePointerDrag {
      defer {
        hostedState.snapshot.viewModel.marqueeSelection = nil
        marqueePointerDrag = nil
      }
      if !marqueeDrag.didBeginDrag {
        hostedState.snapshot.viewModel.clearSelection()
      }
      return true
    }

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
    let point = contentPoint(fromWorkspacePoint: convert(sender.draggingLocation, from: nil))
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
    let point = contentPoint(fromWorkspacePoint: convert(sender.draggingLocation, from: nil))
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

  private func pointerTarget(for hitTarget: PolicyCanvasCanvasHitTarget) -> PointerTarget? {
    switch hitTarget {
    case .node(let id):
      return .node(id)
    case .group(let id):
      return .group(id)
    case .port:
      return nil
    }
  }

  func pointerTarget(at point: CGPoint) -> PointerTarget? {
    let contentPoint = contentPoint(fromWorkspacePoint: point)
    guard
      let hitTarget = hostedState.snapshot.viewModel.canvasHitTarget(
        at: contentPoint,
        portVisibility: hostedState.snapshot.portVisibility,
        portMarkerLayout: hostedState.snapshot.portMarkerLayout
      )
    else {
      return nil
    }
    return pointerTarget(for: hitTarget)
  }

  private func contentPoint(fromWorkspacePoint point: CGPoint) -> CGPoint {
    hostedState.workspaceLayout.contentPoint(forWorkspacePoint: point)
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

  private func recordNativeTrace(
    event: String,
    point: CGPoint,
    details: [String: String] = [:]
  ) {
    guard HarnessMonitorUITestTrace.isEnabled else {
      return
    }
    var payload = details
    payload["x"] = String(format: "%.1f", point.x)
    payload["y"] = String(format: "%.1f", point.y)
    HarnessMonitorUITestTrace.record(
      component: "policy-canvas.native",
      event: event,
      details: payload
    )
  }
}

private final class PolicyCanvasNativeContextMenuTarget: NSObject {
  let target: PolicyCanvasNativeDocumentView.PointerTarget

  init(_ target: PolicyCanvasNativeDocumentView.PointerTarget) {
    self.target = target
  }
}
