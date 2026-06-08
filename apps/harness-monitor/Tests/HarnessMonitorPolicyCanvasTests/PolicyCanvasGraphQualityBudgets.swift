import HarnessMonitorPolicyCanvasAlgorithms

/// Per-sample regression budgets for the graph-quality gate.
///
/// Each limit is the value measured on 2026-06-08 against the `referenceRouting`
/// preset (see `tmp/policy-canvas/graph-quality-baseline.txt`). The gate fails if
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
      .portOverlaps: 6, .portDetached: 5, .corridorReuse: 15, .corridorParallel: 4,
      .crossingsIndependent: 14, .longEdges: 5, .labelOverlaps: 4,
    ],
    "extreme-braid": [
      .portOverlaps: 11, .portDetached: 14, .corridorReuse: 138, .corridorParallel: 119,
      .crossingsIndependent: 360, .longEdges: 53, .labelOverlaps: 20,
    ],
    "extreme-matrix": [
      .portOverlaps: 17, .portDetached: 16, .corridorReuse: 238, .corridorParallel: 157,
      .crossingsIndependent: 539, .bodyHits: 10, .longEdges: 86, .labelOverlaps: 25,
      .labelOnBody: 1,
    ],
    "extreme-mesh": [
      .portOverlaps: 22, .portDetached: 25, .corridorReuse: 416, .corridorParallel: 349,
      .crossingsIndependent: 1492, .bodyHits: 15, .longEdges: 143, .labelOverlaps: 50,
      .labelOnBody: 5,
    ],
    "extreme-lattice": [
      .portOverlaps: 47, .portDetached: 42, .corridorReuse: 1182, .corridorParallel: 600,
      .crossingsIndependent: 4075, .bodyHits: 6, .longEdges: 259, .labelOverlaps: 96,
      .labelOnBody: 3,
    ],
    "extreme-galaxy": [
      .portOverlaps: 74, .portDetached: 66, .corridorReuse: 4633, .corridorParallel: 2634,
      .crossingsIndependent: 11918, .bodyHits: 10, .longEdges: 429, .labelOverlaps: 311,
      .labelOnBody: 8,
    ],
  ]
}
