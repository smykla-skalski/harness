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
    "branching": [.corridorParallel: 2, .detours: 1, .nodeDistance: 1, .labelOverlaps: 2],
    "default": [.longEdges: 2, .detours: 3, .nodeDistance: 2, .labelOverlaps: 1],
    "multi-group": [
      .portOverlaps: 2, .corridorReuse: 3, .corridorParallel: 2,
      .crossingsIndependent: 4, .detours: 2, .nodeDistance: 1, .labelOverlaps: 2,
    ],
    "extreme": [
      .portOverlaps: 4, .corridorReuse: 15, .corridorParallel: 4,
      .crossingsIndependent: 10, .longEdges: 6, .detours: 7, .nodeDistance: 8,
      .labelOverlaps: 3,
    ],
    "extreme-braid": [
      .portOverlaps: 18, .corridorReuse: 175, .corridorParallel: 113,
      .crossingsIndependent: 362, .longEdges: 63, .detours: 13, .nodeDistance: 71,
      .labelOverlaps: 13,
    ],
    "extreme-matrix": [
      .portOverlaps: 24, .corridorReuse: 207, .corridorParallel: 204,
      .crossingsIndependent: 543, .longEdges: 89, .detours: 28, .nodeDistance: 96,
      .labelOverlaps: 21, .labelOnBody: 5,
    ],
    "extreme-mesh": [
      .portOverlaps: 34, .corridorReuse: 424, .corridorParallel: 347,
      .crossingsIndependent: 1215, .longEdges: 142, .detours: 53, .nodeDistance: 159,
      .labelOverlaps: 45, .labelOnBody: 2,
    ],
    "extreme-lattice": [
      .portOverlaps: 62, .corridorReuse: 1036, .corridorParallel: 1297,
      .crossingsIndependent: 3552, .longEdges: 263, .detours: 84, .nodeDistance: 270,
      .labelOverlaps: 92, .labelOnBody: 4,
    ],
    "extreme-galaxy": [
      .portOverlaps: 97, .corridorReuse: 2335, .corridorParallel: 2051,
      .crossingsIndependent: 8808, .longEdges: 422, .detours: 122, .nodeDistance: 438,
      .labelOverlaps: 132, .labelOnBody: 10,
    ],
  ]
}
