import HarnessMonitorPolicyCanvasAlgorithms

/// Per-sample regression budgets for the graph-quality gate.
///
/// Each limit is the value measured on 2026-06-08 against the `referenceRouting`
/// preset (see `tmp/policy-canvas/graph-quality-baseline.txt`), repinned to the
/// current `main` layout. The gate fails if
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
    "linear": [
      .labelNearTurn: 1,
    ],
    "branching": [
      .corridorReuse: 1, .corridorParallel: 1, .detours: 1, .nodeDistance: 1, .wrongTurns: 3,
      .labelNearTurn: 3,
    ],
    "default": [
      .corridorParallel: 3, .longEdges: 2, .detours: 3, .nodeDistance: 2, .wrongTurns: 22,
      .labelNearTurn: 6,
    ],
    "multi-group": [
      .portOverlaps: 2, .corridorReuse: 5, .corridorParallel: 6,
      .crossingsIndependent: 9, .detours: 2, .nodeDistance: 1, .wrongTurns: 9, .crossedPorts: 2,
      .labelOverlaps: 2, .labelOnEdge: 6, .labelNearTurn: 14,
    ],
    "extreme": [
      .portOverlaps: 4, .corridorReuse: 17, .corridorParallel: 11,
      .crossingsIndependent: 12, .longEdges: 6, .detours: 8, .nodeDistance: 8,
      .wrongTurns: 25, .crossedPorts: 5, .labelOverlaps: 2, .labelOnBody: 1,
      .labelOnEdge: 14, .labelNearTurn: 16,
    ],
    "extreme-braid": [
      .portOverlaps: 18, .corridorReuse: 208, .corridorParallel: 65,
      .crossingsIndependent: 327, .longEdges: 63, .detours: 11, .nodeDistance: 71,
      .wrongTurns: 67, .crossedPorts: 7, .labelOverlaps: 11,
      .labelOnEdge: 161, .labelNearTurn: 36,
    ],
  ]
}
