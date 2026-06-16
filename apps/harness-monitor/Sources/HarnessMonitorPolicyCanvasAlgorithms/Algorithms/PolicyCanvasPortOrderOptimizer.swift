import CoreGraphics

private struct PolicyCanvasPortOrderNodeKindKey: Hashable {
  let nodeID: String
  let kind: String
}

private struct PolicyCanvasPortOrderPreference {
  let before: String
  let after: String
}

/// Return nodes whose declared port arrays follow the best-known visual order
/// for their current layout. Same-side edge terminals score the order by where
/// their far nodes sit along that side's axis; ports with no signal keep their
/// current relative order.
public func policyCanvasOptimizedPortOrder(
  nodes: [PolicyCanvasNode],
  edges: [PolicyCanvasEdge]
) -> [PolicyCanvasNode] {
  guard !nodes.isEmpty, !edges.isEmpty else {
    return nodes
  }
  let framesByID = policyCanvasNodeFramesByID(nodes: nodes, edges: edges)
  var signals: [PolicyCanvasPortOrderNodeKindKey: [String: [PolicyCanvasPortSide: [CGFloat]]]] =
    [:]
  signals.reserveCapacity(nodes.count * 2)
  for edge in edges {
    registerPortOrderSignal(
      endpoint: edge.source,
      farNodeID: edge.target.nodeID,
      framesByID: framesByID,
      signals: &signals
    )
    registerPortOrderSignal(
      endpoint: edge.target,
      farNodeID: edge.source.nodeID,
      framesByID: framesByID,
      signals: &signals
    )
  }
  return nodes.map { node in
    var optimized = node
    optimized.inputPorts = optimizedPorts(
      node.inputPorts,
      nodeID: node.id,
      kind: .input,
      signals: signals
    )
    optimized.outputPorts = optimizedPorts(
      node.outputPorts,
      nodeID: node.id,
      kind: .output,
      signals: signals
    )
    return optimized
  }
}

private func registerPortOrderSignal(
  endpoint: PolicyCanvasPortEndpoint,
  farNodeID: String,
  framesByID: [String: CGRect],
  signals: inout [PolicyCanvasPortOrderNodeKindKey: [String: [PolicyCanvasPortSide: [CGFloat]]]]
) {
  guard let farFrame = framesByID[farNodeID] else {
    return
  }
  let side = policyCanvasResolvedPortSide(for: endpoint)
  let key = PolicyCanvasPortOrderNodeKindKey(nodeID: endpoint.nodeID, kind: endpoint.kind.rawValue)
  signals[key, default: [:]][endpoint.portID, default: [:]][side, default: []].append(
    portOrderAxis(side: side, farFrame: farFrame)
  )
}

private func optimizedPorts(
  _ ports: [PolicyCanvasPort],
  nodeID: String,
  kind: PolicyCanvasPortKind,
  signals: [PolicyCanvasPortOrderNodeKindKey: [String: [PolicyCanvasPortSide: [CGFloat]]]]
) -> [PolicyCanvasPort] {
  guard ports.count > 1 else {
    return ports
  }
  let key = PolicyCanvasPortOrderNodeKindKey(nodeID: nodeID, kind: kind.rawValue)
  guard let portSignals = signals[key] else {
    return ports
  }
  let orderedIDs = optimizedPortOrderIDs(portIDs: ports.map(\.id), portSignals: portSignals)
  guard orderedIDs != ports.map(\.id) else {
    return ports
  }
  var portsByID: [String: PolicyCanvasPort] = [:]
  for port in ports {
    portsByID[port.id] = port
  }
  let reordered = orderedIDs.compactMap { portsByID[$0] }
  return reordered.count == ports.count ? reordered : ports
}

private func optimizedPortOrderIDs(
  portIDs: [String],
  portSignals: [String: [PolicyCanvasPortSide: [CGFloat]]]
) -> [String] {
  let preferences = portOrderPreferences(portIDs: portIDs, portSignals: portSignals)
  guard !preferences.isEmpty else {
    return portIDs
  }
  let originalIndex = Dictionary(
    uniqueKeysWithValues: portIDs.enumerated().map {
      ($0.element, $0.offset)
    })
  if portIDs.count <= 7 {
    return exactBestPortOrder(
      portIDs: portIDs,
      preferences: preferences,
      originalIndex: originalIndex
    )
  }
  return locallyOptimizedPortOrder(
    portIDs: portIDs,
    preferences: preferences,
    originalIndex: originalIndex
  )
}

private func portOrderPreferences(
  portIDs: [String],
  portSignals: [String: [PolicyCanvasPortSide: [CGFloat]]]
) -> [PolicyCanvasPortOrderPreference] {
  var preferences: [PolicyCanvasPortOrderPreference] = []
  for side in PolicyCanvasPortSide.allSides {
    let ordered = sideOrderedSignals(side: side, portIDs: portIDs, portSignals: portSignals)
    for leftIndex in ordered.indices {
      for rightIndex in ordered.index(after: leftIndex)..<ordered.endIndex {
        guard ordered[rightIndex].axis - ordered[leftIndex].axis > 0.001 else {
          continue
        }
        preferences.append(
          PolicyCanvasPortOrderPreference(
            before: ordered[leftIndex].id,
            after: ordered[rightIndex].id
          )
        )
      }
    }
  }
  return preferences
}

private func exactBestPortOrder(
  portIDs: [String],
  preferences: [PolicyCanvasPortOrderPreference],
  originalIndex: [String: Int]
) -> [String] {
  var best = portIDs
  var current: [String] = []

  func search(_ remaining: [String]) {
    guard !remaining.isEmpty else {
      if portOrder(
        current,
        isBetterThan: best,
        preferences: preferences,
        originalIndex: originalIndex
      ) {
        best = current
      }
      return
    }

    for index in remaining.indices {
      current.append(remaining[index])
      var nextRemaining = remaining
      nextRemaining.remove(at: index)
      search(nextRemaining)
      current.removeLast()
    }
  }

  search(portIDs)
  return best
}

private func locallyOptimizedPortOrder(
  portIDs: [String],
  preferences: [PolicyCanvasPortOrderPreference],
  originalIndex: [String: Int]
) -> [String] {
  var current = portIDs
  var improved = true
  while improved {
    improved = false
    var bestCandidate = current
    for left in current.indices {
      for right in current.index(after: left)..<current.endIndex {
        var candidate = current
        candidate.swapAt(left, right)
        if portOrder(
          candidate,
          isBetterThan: bestCandidate,
          preferences: preferences,
          originalIndex: originalIndex
        ) {
          bestCandidate = candidate
        }
      }
    }
    if bestCandidate != current {
      current = bestCandidate
      improved = true
    }
  }
  return current
}

private func portOrder(
  _ candidate: [String],
  isBetterThan current: [String],
  preferences: [PolicyCanvasPortOrderPreference],
  originalIndex: [String: Int]
) -> Bool {
  let candidatePenalty = portOrderPenalty(candidate, preferences: preferences)
  let currentPenalty = portOrderPenalty(current, preferences: preferences)
  if candidatePenalty != currentPenalty {
    return candidatePenalty < currentPenalty
  }
  let candidateMovement = portOrderMovement(candidate, originalIndex: originalIndex)
  let currentMovement = portOrderMovement(current, originalIndex: originalIndex)
  if candidateMovement != currentMovement {
    return candidateMovement < currentMovement
  }
  return portOrderOriginalIndexPath(
    candidate,
    isLessThan: current,
    originalIndex: originalIndex
  )
}

private func portOrderPenalty(
  _ portIDs: [String],
  preferences: [PolicyCanvasPortOrderPreference]
) -> Int {
  let positions = Dictionary(
    uniqueKeysWithValues: portIDs.enumerated().map {
      ($0.element, $0.offset)
    })
  return preferences.reduce(into: 0) { penalty, preference in
    guard
      let beforePosition = positions[preference.before],
      let afterPosition = positions[preference.after],
      beforePosition > afterPosition
    else {
      return
    }
    penalty += 1
  }
}

private func portOrderMovement(
  _ portIDs: [String],
  originalIndex: [String: Int]
) -> Int {
  portIDs.enumerated().reduce(into: 0) { movement, entry in
    movement += abs(entry.offset - (originalIndex[entry.element] ?? entry.offset))
  }
}

private func portOrderOriginalIndexPath(
  _ candidate: [String],
  isLessThan current: [String],
  originalIndex: [String: Int]
) -> Bool {
  for (left, right) in zip(candidate, current) {
    let leftIndex = originalIndex[left] ?? .max
    let rightIndex = originalIndex[right] ?? .max
    if leftIndex != rightIndex {
      return leftIndex < rightIndex
    }
  }
  return candidate.count < current.count
}

private func sideOrderedSignals(
  side: PolicyCanvasPortSide,
  portIDs: [String],
  portSignals: [String: [PolicyCanvasPortSide: [CGFloat]]]
) -> [(id: String, axis: CGFloat)] {
  let portIDSet = Set(portIDs)
  return portSignals.compactMap { portID, sideSignals -> (id: String, axis: CGFloat)? in
    guard portIDSet.contains(portID),
      let axes = sideSignals[side],
      !axes.isEmpty
    else {
      return nil
    }
    return (portID, axes.reduce(0, +) / CGFloat(axes.count))
  }
  .sorted { left, right in
    if abs(left.axis - right.axis) > 0.001 {
      return left.axis < right.axis
    }
    return (portIDs.firstIndex(of: left.id) ?? .max) < (portIDs.firstIndex(of: right.id) ?? .max)
  }
}

private func portOrderAxis(side: PolicyCanvasPortSide, farFrame: CGRect) -> CGFloat {
  switch side {
  case .leading, .trailing:
    farFrame.midY
  case .top, .bottom:
    farFrame.midX
  }
}
