import HarnessMonitorPolicyCanvasAlgorithms

/// Per-sample regression budgets for the graph-quality gate.
///
/// Each limit is the value measured on 2026-06-08 against the `referenceRouting`
/// preset (see `tmp/policy-canvas/graph-quality-baseline.txt`), repinned to the
/// current `main` layout. The gate fails if
/// a sample regresses above its budget; improvements just leave headroom, so
/// tighten the budget whenever a category is banked lower. Categories absent from
/// a sample's table default to `0` - a hard-zero gate. A sample with no entry at
/// all (e.g. a newly added lab sample) gets all-zero budgets and fails loudly
/// until its baseline is captured. `PolicyCanvasQualityCategory.crossings` is the
/// only non-gated category.
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
    ],
    "default": [
      .corridorParallel: 3, .longEdges: 2, .detours: 3, .nodeDistance: 2, .wrongTurns: 22,
    ],
    "multi-group": [
      .portOverlaps: 2, .corridorReuse: 5, .corridorParallel: 6,
      .crossingsIndependent: 9, .detours: 2, .nodeDistance: 1, .wrongTurns: 9, .labelOverlaps: 2,
    ],
    "extreme": [
      .portOverlaps: 4, .corridorReuse: 17, .corridorParallel: 11,
      .crossingsIndependent: 12, .longEdges: 6, .detours: 8, .nodeDistance: 8,
      .wrongTurns: 25, .labelOverlaps: 2, .labelOnBody: 1,
    ],
    "extreme-braid": [
      .portOverlaps: 18, .corridorReuse: 208, .corridorParallel: 65,
      .crossingsIndependent: 327, .longEdges: 63, .detours: 11, .nodeDistance: 71,
      .wrongTurns: 67, .labelOverlaps: 11,
    ],
    "extreme-matrix": [
      .portOverlaps: 24, .corridorReuse: 327, .corridorParallel: 193,
      .crossingsIndependent: 447, .longEdges: 89, .detours: 31, .nodeDistance: 96,
      .wrongTurns: 90, .labelOverlaps: 24,
    ],
    "extreme-mesh": [
      .portOverlaps: 34, .corridorReuse: 527, .corridorParallel: 373,
      .crossingsIndependent: 1168, .longEdges: 142, .detours: 47, .nodeDistance: 159,
      .wrongTurns: 161, .labelOverlaps: 42, .labelOnBody: 3,
    ],
    "extreme-lattice": [
      .portOverlaps: 62, .corridorReuse: 1945, .corridorParallel: 906,
      .crossingsIndependent: 2773, .longEdges: 263, .detours: 100, .nodeDistance: 270,
      .wrongTurns: 240, .labelOverlaps: 105, .labelOnBody: 1,
    ],
    "extreme-galaxy": [
      .portOverlaps: 97, .corridorReuse: 3024, .corridorParallel: 2184,
      .crossingsIndependent: 7973, .longEdges: 422, .detours: 108, .nodeDistance: 438,
      .wrongTurns: 376, .labelOverlaps: 139, .labelOnBody: 4,
    ],
  ]
}
