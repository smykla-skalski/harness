import Foundation
import SwiftUI

// Geometry-derived spacing for the decision-terminal comb. The arrangement sizes
// itself from the real edge geometry - port turn leads, the edge-label band, and
// the node box - instead of a layout-config row/column spacing knob, so any
// policy's terminals sit as close as their own edges allow rather than at one
// fixed distance. Nothing here reads a configured spacing value.
private enum PolicyCanvasTerminalCombMetrics {
  // Source bottom -> branch-terminal top: an exit turn lead and an entry turn
  // lead. A straight labeled drop (a deny rail) carries its label on the vertical
  // and the label height fits inside the two leads with clearance to spare; a
  // fan-out drop carries its label on the mid horizontal, outside the vertical
  // band entirely. So two leads is the tightest drop that reads on both.
  static var branchVerticalGap: CGFloat {
    PolicyCanvasLayout.nodeSize.height
      + (2 * PolicyCanvasLayout.edgePortTurnMinimumLead)
  }

  // Sibling terminals: one node width plus a single turn lead of gutter, enough
  // for a rail to turn through the gap without grazing either body.
  static var horizontalStep: CGFloat {
    PolicyCanvasLayout.nodeSize.width + PolicyCanvasLayout.edgePortTurnMinimumLead
  }

  // A shared collector lifts just far enough above its sources for the fan-in
  // rails to nest in distinct lanes: the node box, a turn-lead margin at each end
  // (the outermost rail's drop into the collector and the innermost rail's rise
  // off its source both read as corners, clear of every port), and one
  // label-height band per extra lane level on the busier approach side. Scales
  // with the fan-in width so a six-rail collector rides a little higher than a
  // three-rail one, but no higher than the rails actually need.
  static func collectorLift(sourceCount: Int) -> CGFloat {
    let levelsPerSide = max(1, Int((Double(sourceCount) / 2).rounded(.up)))
    let laneBand = CGFloat(levelsPerSide - 1) * PolicyCanvasLayout.edgeLabelHeight
    return PolicyCanvasLayout.nodeSize.height
      + (2 * PolicyCanvasLayout.edgePortTurnMinimumLead)
      + laneBand
  }
}

/// Arrange a decision pipeline's terminal nodes into a "comb" around the flow
/// spine instead of stacking them all into one downstream column.
///
/// The generic layered engine ranks every downstream terminal into the rightmost
/// rank column. For a decision pipeline - a chain of checks where each check
/// branches to its own single-purpose terminal (a deny rule) plus one shared
/// collector (the human gate every check's "missing" rail feeds) - that column
/// forces two long-haul families through the same corridor: each deny edge runs
/// the full width to the column while the collector fans in across the whole
/// span. They cross. This pass rebuilds the terminal placement so branch
/// terminals drop straight DOWN beneath their source (short vertical rails) and
/// shared collectors lift straight UP, centered over their sources (a fan that
/// never meets the down-rails). With the two families on opposite sides of the
/// spine the corridor is no longer shared, so the crossings disappear.
///
/// It only engages when the graph actually has a shared collector (a sink fed by
/// three or more distinct sources); ordinary policies keep the generic layout.
/// All spacing is computed from `PolicyCanvasTerminalCombMetrics`, not a config.
func policyCanvasArrangedDecisionTerminals(
  nodePositions: [String: CGPoint],
  edges: [PolicyCanvasLayoutEdge]
) -> [String: CGPoint] {
  var sourcesByTarget: [String: [String]] = [:]
  var outDegree: [String: Int] = [:]
  for edge in edges {
    if !(sourcesByTarget[edge.targetNodeID]?.contains(edge.sourceNodeID) ?? false) {
      sourcesByTarget[edge.targetNodeID, default: []].append(edge.sourceNodeID)
    }
    outDegree[edge.sourceNodeID, default: 0] += 1
  }
  let sinkIDs = sourcesByTarget.keys.filter { (outDegree[$0] ?? 0) == 0 }
  let collectors = sinkIDs.filter { (sourcesByTarget[$0]?.count ?? 0) >= 3 }
  guard !collectors.isEmpty else {
    return nodePositions
  }

  var positions = nodePositions
  let branchDrop = PolicyCanvasTerminalCombMetrics.branchVerticalGap
  let columnStep = PolicyCanvasTerminalCombMetrics.horizontalStep

  // Branch terminals (one or two sources) drop beneath their primary (left-most)
  // source; siblings sharing a source spread sideways so they never overlap.
  var branchSinksBySource: [String: [String]] = [:]
  for sink in sinkIDs where !collectors.contains(sink) {
    let sources = sourcesByTarget[sink] ?? []
    guard
      let primary = sources.min(by: {
        (positions[$0]?.x ?? 0) < (positions[$1]?.x ?? 0)
      })
    else { continue }
    branchSinksBySource[primary, default: []].append(sink)
  }
  for (source, sinks) in branchSinksBySource {
    guard let sourcePoint = positions[source] else { continue }
    let ordered = sinks.sorted { (positions[$0]?.x ?? 0) < (positions[$1]?.x ?? 0) }
    let count = ordered.count
    for (index, sink) in ordered.enumerated() {
      let offset = (CGFloat(index) - CGFloat(count - 1) / 2) * columnStep
      positions[sink] = CGPoint(x: sourcePoint.x + offset, y: sourcePoint.y + branchDrop)
    }
  }

  // Shared collectors lift straight up, centered over their sources; a wider
  // fan-in rides higher (its own lift scales with source count) and additional
  // collectors stack above so they keep clear lanes.
  let orderedCollectors = collectors.sorted {
    (sourcesByTarget[$0]?.count ?? 0) > (sourcesByTarget[$1]?.count ?? 0)
  }
  var stackedLift: CGFloat = 0
  for collector in orderedCollectors {
    let sources = sourcesByTarget[collector] ?? []
    let sourcePoints = sources.compactMap { positions[$0] }
    guard !sourcePoints.isEmpty else { continue }
    let centerX = sourcePoints.map(\.x).reduce(0, +) / CGFloat(sourcePoints.count)
    let topSourceY = sourcePoints.map(\.y).min() ?? 0
    let lift = PolicyCanvasTerminalCombMetrics.collectorLift(sourceCount: sources.count)
    positions[collector] = CGPoint(x: centerX, y: topSourceY - lift - stackedLift)
    stackedLift += lift
  }
  return policyCanvasSpreadOverlappingRows(positions: positions)
}

/// Spread nodes the terminal comb dropped within a node-width of a row neighbor.
/// Each source's branch sinks are centered on that source, so sinks from adjacent
/// sources (consensus under protected-path, auto-merge under risk) can overlap.
/// Per row, left to right, push any node closer than one horizontal step to its
/// left neighbor out to that minimum. The left end of each row stays put, so a
/// node already clear of its neighbor never moves. The minimum is the same
/// computed step the comb spreads siblings with - no configured spacing.
func policyCanvasSpreadOverlappingRows(
  positions: [String: CGPoint]
) -> [String: CGPoint] {
  let minimumGap = PolicyCanvasTerminalCombMetrics.horizontalStep
  var result = positions
  let rows = Dictionary(grouping: positions.keys) { Int((positions[$0]?.y ?? 0).rounded()) }
  for ids in rows.values where ids.count > 1 {
    let ordered = ids.sorted { (positions[$0]?.x ?? 0) < (positions[$1]?.x ?? 0) }
    for index in 1..<ordered.count {
      guard
        let previous = result[ordered[index - 1]],
        let current = result[ordered[index]]
      else { continue }
      let minimumX = previous.x + minimumGap
      if current.x < minimumX {
        result[ordered[index]] = CGPoint(x: minimumX, y: current.y)
      }
    }
  }
  return result
}
