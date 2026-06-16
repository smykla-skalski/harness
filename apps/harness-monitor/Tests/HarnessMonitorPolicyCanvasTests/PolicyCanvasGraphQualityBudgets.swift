import HarnessMonitorPolicyCanvasAlgorithms

/// Per-sample regression budgets for the graph-quality gate.
///
/// Each limit is the value measured on 2026-06-08 against the `referenceRouting`
/// preset (see `tmp/policy-canvas/graph-quality-baseline.txt`), repinned to the
/// current `main` layout. The label budgets were repinned again on 2026-06-16
/// once the report began boxing labels at their resolved render positions
/// (`labelPositions`) instead of the raw route midpoint, which both surfaced
/// genuine adrift labels and banked large on-edge improvements. The gate fails if
/// a sample regresses above its budget; improvements just leave headroom, so
/// tighten the budget whenever a category is banked lower. Categories absent from
/// a sample's table default to `0` - a hard-zero gate. A budgeted sample with no
/// entry at all (e.g. a newly added non-debug lab sample) gets all-zero budgets
/// and fails loudly until its baseline is captured. The four largest stress
/// fixtures are debug-only for this gate and stay covered by the deterministic
/// dump. `PolicyCanvasQualityCategory.crossings` is the only non-gated category.
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
    "linear": [:],
    "branching": [
      .corridorReuse: 1, .corridorParallel: 1, .detours: 1, .nodeDistance: 1, .wrongTurns: 3,
      .labelAdrift: 1,
    ],
    "default": [
      .corridorParallel: 3, .longEdges: 2, .detours: 3, .nodeDistance: 2, .wrongTurns: 22,
      .labelNearTurn: 6,
    ],
    "multi-group": [
      .portOverlaps: 2, .corridorReuse: 6, .corridorParallel: 6,
      .crossingsIndependent: 9, .detours: 2, .nodeDistance: 1, .wrongTurns: 10, .crossedPorts: 0,
      .labelAdrift: 1, .labelOnEdge: 2, .labelNearTurn: 11,
    ],
    "extreme": [
      .portOverlaps: 4, .corridorReuse: 17, .corridorParallel: 11,
      .crossingsIndependent: 12, .longEdges: 6, .detours: 8, .nodeDistance: 8,
      .wrongTurns: 25, .crossedPorts: 0,
      .labelAdrift: 1, .labelOnEdge: 5, .labelNearTurn: 10,
    ],
    "extreme-braid": [
      .portOverlaps: 18, .corridorReuse: 208, .corridorParallel: 66,
      .crossingsIndependent: 327, .longEdges: 63, .detours: 11, .nodeDistance: 71,
      .wrongTurns: 70, .crossedPorts: 0,
      .labelOnEdge: 16, .labelNearTurn: 31,
    ],
  ]
}
