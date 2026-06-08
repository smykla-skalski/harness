import HarnessMonitorPolicyCanvasAlgorithms

/// Per-sample regression budgets for the graph-quality gate.
///
/// Each limit is the value measured on 2026-06-08 against the `referenceRouting`
/// preset (see `tmp/policy-canvas/graph-quality-baseline.txt`), repinned after the
/// layout-placement-pressure change on `main`. The gate fails if
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
    "branching": [.corridorParallel: 2, .labelOverlaps: 2],
    "default": [.portOverlaps: 2, .portDetached: 1, .longEdges: 2, .labelOverlaps: 1],
    "multi-group": [
      .portOverlaps: 4, .portDetached: 2, .corridorReuse: 3, .corridorParallel: 2,
      .crossingsIndependent: 4, .labelOverlaps: 2,
    ],
    "extreme": [
      .portOverlaps: 6, .portDetached: 5, .corridorReuse: 16, .corridorParallel: 8,
      .crossingsIndependent: 25, .longEdges: 20, .labelOverlaps: 6,
    ],
    "extreme-braid": [
      .portOverlaps: 9, .portDetached: 12, .corridorReuse: 126, .corridorParallel: 84,
      .crossingsIndependent: 368, .longEdges: 76, .labelOverlaps: 6,
    ],
    "extreme-matrix": [
      .portOverlaps: 13, .portDetached: 16, .corridorReuse: 164, .corridorParallel: 103,
      .crossingsIndependent: 405, .longEdges: 104, .labelOverlaps: 11, .labelOnBody: 8,
    ],
    "extreme-mesh": [
      .portOverlaps: 19, .portDetached: 25, .corridorReuse: 302, .corridorParallel: 214,
      .crossingsIndependent: 1021, .longEdges: 162, .labelOverlaps: 20, .labelOnBody: 7,
    ],
    "extreme-lattice": [
      .portOverlaps: 31, .portDetached: 39, .corridorReuse: 698, .corridorParallel: 590,
      .crossingsIndependent: 3104, .longEdges: 267, .labelOverlaps: 47, .labelOnBody: 3,
    ],
    "extreme-galaxy": [
      .portOverlaps: 51, .portDetached: 66, .corridorReuse: 1527, .corridorParallel: 984,
      .crossingsIndependent: 7152, .bodyHits: 3, .longEdges: 442, .labelOverlaps: 55,
      .labelOnBody: 9,
    ],
  ]
}
