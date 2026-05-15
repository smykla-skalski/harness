import SwiftUI

extension PolicyCanvasViewModel {
  func accessibilityLabel(for node: PolicyCanvasNode) -> String {
    "\(node.kind.title) \(node.title)"
  }

  func accessibilityValue(for node: PolicyCanvasNode) -> String {
    var parts: [String] = []
    if let groupID = node.groupID, let group = group(groupID) {
      parts.append("group \(group.title)")
    }
    let outgoing = connectedTitles(for: node.id, direction: .outgoing)
    if !outgoing.isEmpty {
      parts.append("connects to: \(outgoing.joined(separator: ", "))")
    }
    let incoming = connectedTitles(for: node.id, direction: .incoming)
    if !incoming.isEmpty {
      parts.append("receives from: \(incoming.joined(separator: ", "))")
    }
    return parts.joined(separator: ", ")
  }

  private enum EdgeDirection {
    case outgoing
    case incoming
  }

  private func connectedTitles(for nodeID: String, direction: EdgeDirection) -> [String] {
    edges.compactMap { edge in
      switch direction {
      case .outgoing:
        return edge.source.nodeID == nodeID ? self.node(edge.target.nodeID)?.title : nil
      case .incoming:
        return edge.target.nodeID == nodeID ? self.node(edge.source.nodeID)?.title : nil
      }
    }
  }

  func accessibilityLabel(for edge: PolicyCanvasEdge) -> String {
    let sourceNode = node(edge.source.nodeID)
    let targetNode = node(edge.target.nodeID)
    let sourcePort = sourceNode?.outputPorts.first { $0.id == edge.source.portID }
    let targetPort = targetNode?.inputPorts.first { $0.id == edge.target.portID }
    let sourcePiece = [sourceNode?.title, sourcePort?.title]
      .compactMap { $0 }
      .joined(separator: " ")
    let targetPiece = [targetNode?.title, targetPort?.title]
      .compactMap { $0 }
      .joined(separator: " ")
    let edgeName = edge.label.isEmpty ? "connection" : edge.label
    if sourcePiece.isEmpty || targetPiece.isEmpty {
      return "Edge \(edgeName)"
    }
    return "Edge \(edgeName), from \(sourcePiece) to \(targetPiece)"
  }

  /// Accessible value pairing an edge's *kind* and animation state so the
  /// screen reader hears information that sighted users perceive from the
  /// stroke color and dash march. Without this, VoiceOver users have no
  /// path to the kind distinction the cyan/purple/red palette encodes -
  /// which would fail WCAG 1.4.1 (color as the sole signal). The value is
  /// composable: `"flow"`, `"control"`, or `"error"`, optionally suffixed
  /// with `", active"` when the edge is animated *and* motion is allowed.
  /// Pass the active flag in from the rendering layer so the value reflects
  /// the same reduce-motion gate the stroke layer uses.
  func accessibilityValue(for edge: PolicyCanvasEdge, isAnimating: Bool = false) -> String {
    let kindWord = edge.kind.accessibilityWord
    if isAnimating {
      return "\(kindWord), active"
    }
    return kindWord
  }

  /// Visual-order traversal of `nodes` for keyboard focus and the VoiceOver
  /// nodes rotor. Nodes are sorted top-to-bottom, then left-to-right within
  /// the same row (10pt tolerance to absorb minor y-axis drift after snap).
  /// Returns ids only — callers build the rotor entries lazily from these to
  /// avoid retaining live nodes in the rotor content closure.
  func accessibilityNodeFocusOrder() -> [String] {
    nodes
      .sorted { left, right in
        let rowDelta = left.position.y - right.position.y
        if abs(rowDelta) >= 10 {
          return rowDelta < 0
        }
        return left.position.x < right.position.x
      }
      .map(\.id)
  }

  /// Duplicates the node by id, offsetting the copy by 20pt on both axes so
  /// the clone is visible alongside its source. The new node carries the same
  /// kind/group/policy binding but no incident edges; ports keep stable ids
  /// because they are kind-scoped (not node-scoped). Used by the per-node
  /// accessibility action and the future Cmd+D shortcut.
  @discardableResult
  func duplicateNode(_ id: String) -> String? {
    guard let original = node(id) else {
      return nil
    }
    let number = nextNodeNumber
    nextNodeNumber += 1
    let cloneID = "\(original.kind.rawValue)-\(number)"
    var clone = PolicyCanvasNode(
      id: cloneID,
      title: "\(original.title) copy",
      kind: original.kind,
      position: snapped(
        CGPoint(
          x: original.position.x + 20,
          y: original.position.y + 20
        )
      )
    )
    clone.groupID = original.groupID
    clone.policyKind = original.policyKind
    nodes.append(clone)
    reconcileGroupFrames()
    selection = .node(cloneID)
    documentDirty = true
    invalidateValidationCache()
    notifyStatus("Duplicated \(original.title)")
    return cloneID
  }

  /// Reachable input ports for a "Connect to..." rotor or shortcut. Skips the
  /// node itself and any input already wired from this output. Used by the
  /// per-node accessibility action so VoiceOver users can wire an edge
  /// without dragging.
  func accessibilityConnectableTargets(
    fromNodeID nodeID: String
  ) -> [PolicyCanvasPortEndpoint] {
    guard let source = node(nodeID),
      let sourcePort = source.outputPorts.first
    else {
      return []
    }
    let sourceEndpoint = PolicyCanvasPortEndpoint(
      nodeID: nodeID,
      portID: sourcePort.id,
      kind: .output
    )

    return
      nodes
      .filter { $0.id != nodeID }
      .flatMap { target in
        target.inputPorts.map { port in
          PolicyCanvasPortEndpoint(
            nodeID: target.id,
            portID: port.id,
            kind: .input
          )
        }
      }
      .filter { candidate in
        !edges.contains { edge in
          edge.source == sourceEndpoint && edge.target == candidate
        }
      }
  }

  /// Maximum per-target Connect actions stamped onto a single node card. Six
  /// is the VoiceOver rotor floor where the rotor stays usable — beyond that
  /// the action list becomes a navigation problem instead of a shortcut. The
  /// dropped tail is reachable through edge-drag or by selecting a different
  /// source node, so this is a discoverability cap, not a feature cap.
  static let accessibilityConnectableTargetActionCap: Int = 6

  /// Display name plus endpoint pair for the per-target Connect actions on a
  /// node card. The display name is `"<target node title> <target port title>"`
  /// so VoiceOver announces "Connect to Risk score event" (not just "Connect")
  /// when the user invokes the rotor entry. `id` is stable across renders
  /// because it composes the target node + port id, both of which the data
  /// model treats as document-stable strings.
  struct AccessibilityConnectTarget: Identifiable, Hashable {
    let endpoint: PolicyCanvasPortEndpoint
    let displayName: String
    var id: String { "\(endpoint.nodeID)|\(endpoint.portID)" }
  }

  /// Per-target reachable inputs, decorated with display names for the
  /// accessibility action rotor. Capped at the configured action-cap above to
  /// keep the per-node rotor entry list usable. Source ordering matches the
  /// underlying reachable enumeration (visual-order ish), so a VoiceOver user
  /// gets the same first-hit a sighted user would.
  func accessibilityConnectableNamedTargets(
    fromNodeID nodeID: String
  ) -> [AccessibilityConnectTarget] {
    accessibilityConnectableTargets(fromNodeID: nodeID)
      .prefix(Self.accessibilityConnectableTargetActionCap)
      .compactMap { endpoint -> AccessibilityConnectTarget? in
        guard let target = node(endpoint.nodeID),
          let port = target.inputPorts.first(where: { $0.id == endpoint.portID })
        else {
          return nil
        }
        return AccessibilityConnectTarget(
          endpoint: endpoint,
          displayName: "\(target.title) \(port.title)"
        )
      }
  }

  /// Builds the wire payload for the first available output port on a node.
  /// Returns nil when the node has no outputs (e.g. terminal decisions). Used
  /// by `accessibilityConnect(fromNodeID:to:)` to mirror the `.draggable`
  /// payload format without crossing the gesture seam.
  func accessibilityConnect(
    fromNodeID nodeID: String,
    to target: PolicyCanvasPortEndpoint
  ) -> Bool {
    guard let source = node(nodeID),
      let sourcePort = source.outputPorts.first
    else {
      return false
    }
    return connectDroppedPortPayloads(
      [portDragPayload(nodeID: nodeID, portID: sourcePort.id)],
      targetNodeID: target.nodeID,
      targetPortID: target.portID
    )
  }

  /// Open the inspector on the given node by selecting it and raising the
  /// draft tab so the form is visible. Mirrors what the right-click "Open
  /// inspector" path does for mouse users.
  func accessibilityOpenInspector(forNodeID nodeID: String) {
    selectedTab = .draft
    select(.node(nodeID))
  }
}
