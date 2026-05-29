import CoreGraphics

/// Layout intent passed into `PolicyCanvasLayeredLayoutEngine`. Split out of
/// `PolicyCanvasAutomaticLayoutEngine.swift` so the three derived policies
/// (anchor pinning, canvas centering, order seeding) read in one place.
enum PolicyCanvasAutomaticLayoutMode: Sendable, Equatable {
  case initialLoad
  /// `preserveManualAnchors`: pin nodes the user dragged and only re-place the
  /// auto ones. A reflow always seeds the within-layer order from each node's
  /// current row, so reformatting an already-laid-out graph reproduces it (a
  /// fixed point) whether those positions came from a prior auto layout or from
  /// trusted saved coordinates. Reformat tidies layering and spacing without
  /// reshuffling rows the user already sees.
  case explicitReflow(preserveManualAnchors: Bool)

  var preservesManualAnchors: Bool {
    switch self {
    case .initialLoad:
      false
    case .explicitReflow(let preserveManualAnchors):
      preserveManualAnchors
    }
  }

  var centersInMinimumCanvas: Bool {
    switch self {
    case .initialLoad:
      true
    case .explicitReflow(let preserveManualAnchors):
      !preserveManualAnchors
    }
  }

  /// How the within-layer order seed is derived before Brandes-Köpf runs.
  var orderSeedStrategy: PolicyCanvasOrderSeedStrategy {
    switch self {
    case .initialLoad:
      // Nothing trustworthy to preserve yet (positions are whatever the
      // document happened to persist), so derive a low-crossing starting order
      // from each node's neighbours - terminals cluster near their sources.
      .neighborBarycenter
    case .explicitReflow:
      // Seed from each node's own current row so reformatting an already-laid-out
      // graph reproduces it instead of reshuffling rows.
      .currentPosition
    }
  }
}

/// Source of the per-node Y used to seed within-layer ordering. `initialLoad`
/// borrows neighbours' rows; a reflow keeps each node's own current row so the
/// arrangement the user already sees is preserved.
enum PolicyCanvasOrderSeedStrategy: Sendable, Equatable {
  case neighborBarycenter
  case currentPosition
}
