import HarnessMonitorPolicyCanvasAlgorithms

/// Per-sample regression budgets for the graph-quality gate.
///
/// Each limit is the value measured on 2026-06-08 against the `referenceRouting`
/// preset (see `tmp/policy-canvas/graph-quality-baseline.txt`), repinned to the
/// current `main` layout. The label budgets were repinned again on 2026-06-16
/// once the report began boxing labels at their resolved render positions
/// (`labelPositions`) instead of the raw route midpoint, which both surfaced
/// genuine adrift labels and banked large on-edge improvements. The crossed-port
/// budgets were repinned again on 2026-06-17 once the measure began detecting
/// crossings geometrically instead of from a one-dimensional order key, which
/// surfaced real fan-in crossings the old key was blind to. The budgets were
/// repinned again on 2026-06-17 after ELK became the only automatic layout path
/// for small and large samples, and again after the route grid / corridor-spacing
/// pass made corridor reuse and parallel corridor spacing hard-zero gates.
/// Corridor reuse and corridor parallel stay intentionally absent so every
/// budgeted sample has a hard-zero corridor gate.
/// The gate fails if a sample regresses above its budget; improvements just leave
/// headroom, so tighten the budget whenever a category is banked lower. Categories
/// absent from a sample's table default to `0` - a hard-zero gate. A budgeted
/// sample with no entry at all (e.g. a newly added non-debug lab sample) gets
/// all-zero budgets and fails loudly until its baseline is captured. The four
/// largest stress fixtures are debug-only for this gate and stay covered by the
/// deterministic dump. Corridor reuse and parallel corridor spacing are hard-zero
/// gates in `PolicyCanvasGraphQualityGateTests`. `PolicyCanvasQualityCategory.crossings`
/// is the only non-gated category.
enum PolicyCanvasGraphQualityBudgets {
  /// Allowed count for a category on a given sample. Missing entries are `0`.
  static func limit(
    _ category: PolicyCanvasQualityCategory,
    forSampleID sampleID: String
  ) -> Int {
    bySampleID[sampleID]?[category] ?? 0
  }

  static let bySampleID: [String: [PolicyCanvasQualityCategory: Int]] = [
    "minimal": [:],
    "linear": [
      .crossedPorts: 1, .labelNearTurn: 2,
    ],
    "branching": [
      .crossedPorts: 5, .labelOnEdge: 4, .labelNearTurn: 3,
    ],
    "default": [
      .crossingsIndependent: 4, .longEdges: 4, .detours: 2, .nodeDistance: 5,
      .wrongTurns: 2, .crossedPorts: 10, .labelOnBody: 1, .labelOnEdge: 5,
      .labelNearTurn: 8,
    ],
    "multi-group": [
      .crossingsIndependent: 12, .longEdges: 5, .nodeDistance: 7, .crossedPorts: 7,
      .labelOverlaps: 1, .labelOnBody: 1, .labelOnEdge: 3, .labelNearTurn: 11,
    ],
    "extreme": [
      .crossingsIndependent: 22, .longEdges: 5, .nodeDistance: 6, .crossedPorts: 5,
      .labelOverlaps: 1, .labelOnBody: 4, .labelOnEdge: 20, .labelNearTurn: 12,
    ],
    "extreme-braid": [
      .crossingsIndependent: 53, .longEdges: 15, .detours: 3, .nodeDistance: 27,
      .wrongTurns: 4, .crossedPorts: 13, .labelOverlaps: 1, .labelOnBody: 3,
      .labelOnEdge: 26, .labelNearTurn: 30,
    ],
  ]
}
