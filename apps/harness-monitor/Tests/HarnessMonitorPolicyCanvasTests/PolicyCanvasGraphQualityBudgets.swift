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
/// surfaced real fan-in crossings the old key was blind to. Corridor reuse stays
/// intentionally absent so every budgeted sample has a hard-zero reuse gate.
/// The gate fails if a sample regresses above its budget; improvements just leave
/// headroom, so tighten the budget whenever a category is banked lower. Categories
/// absent from a sample's table default to `0` - a hard-zero gate. A budgeted
/// sample with no entry at all (e.g. a newly added non-debug lab sample) gets
/// all-zero budgets and fails loudly until its baseline is captured. The four
/// largest stress fixtures are debug-only for this gate and stay covered by the
/// deterministic dump. `PolicyCanvasQualityCategory.crossings` is the only
/// non-gated category.
enum PolicyCanvasGraphQualityBudgets {
  /// Allowed count for a category on a given sample. Missing entries are `0`.
  static func limit(
    _ category: PolicyCanvasQualityCategory,
    forSampleID sampleID: String
  ) -> Int {
    bySampleID[sampleID]?[category] ?? 0
  }

  static let bySampleID: [String: [PolicyCanvasQualityCategory: Int]] = [
    "minimal": [
      .labelNearTurn: 1
    ],
    "linear": [
      .wrongTurns: 2, .labelNearTurn: 3,
    ],
    "branching": [
      .corridorParallel: 2, .detours: 1, .nodeDistance: 1, .wrongTurns: 4,
      .crossedPorts: 1, .labelOnEdge: 1, .labelNearTurn: 4,
    ],
    "default": [
      .corridorParallel: 6, .longEdges: 3, .nodeDistance: 2, .wrongTurns: 31,
      .crossedPorts: 5, .labelOnEdge: 1, .labelNearTurn: 7,
    ],
    "multi-group": [
      .corridorParallel: 9, .crossingsIndependent: 10, .longEdges: 3, .detours: 1,
      .nodeDistance: 1, .wrongTurns: 19, .crossedPorts: 8, .labelOnEdge: 2,
      .labelNearTurn: 7,
    ],
    "extreme": [
      .corridorParallel: 29, .crossingsIndependent: 40, .longEdges: 12, .detours: 7,
      .nodeDistance: 19, .wrongTurns: 43, .crossedPorts: 4, .labelOnEdge: 4,
      .labelNearTurn: 5,
    ],
    "extreme-braid": [
      .corridorParallel: 348, .crossingsIndependent: 345, .longEdges: 67, .detours: 33,
      .nodeDistance: 73, .wrongTurns: 102, .crossedPorts: 7, .labelOnEdge: 10,
      .labelNearTurn: 27,
    ],
  ]
}
