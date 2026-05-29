import CoreGraphics

/// Layout intent passed into `PolicyCanvasLayeredLayoutEngine`. Split out of
/// `PolicyCanvasAutomaticLayoutEngine.swift` so the three derived policies
/// (anchor pinning, canvas centering, order seeding) read in one place.
enum PolicyCanvasAutomaticLayoutMode: Sendable, Equatable {
  case initialLoad
  /// `preserveManualAnchors`: pin nodes the user dragged and only re-place the
  /// auto ones. `preservesGeometryOrder`: seed the within-layer order from each
  /// node's current row (true) instead of resetting to document order (false).
  /// A graph that still carries a prior auto layout keeps its arrangement so
  /// Reformat is a fixed point; a fully-manual graph has no auto layout to keep
  /// and resets to graph order when its anchors are dropped.
  case explicitReflow(preserveManualAnchors: Bool, preservesGeometryOrder: Bool)

  var preservesManualAnchors: Bool {
    switch self {
    case .initialLoad:
      false
    case .explicitReflow(let preserveManualAnchors, _):
      preserveManualAnchors
    }
  }

  var centersInMinimumCanvas: Bool {
    switch self {
    case .initialLoad:
      true
    case .explicitReflow(let preserveManualAnchors, _):
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
    case .explicitReflow(_, let preservesGeometryOrder):
      // A reflow that keeps the arrangement seeds from each node's own current
      // row, so reformatting an already-laid-out graph reproduces it (a fixed
      // point) instead of reshuffling rows. The reset variant falls back to
      // document order, which is what a fully-manual reflow asks for once its
      // anchors are dropped.
      preservesGeometryOrder ? .currentPosition : .documentOrder
    }
  }
}

/// Source of the per-node Y used to seed within-layer ordering. `initialLoad`
/// borrows neighbours' rows; a reflow that preserves its arrangement keeps each
/// node's own row; a reflow that resets falls back to stable document order.
enum PolicyCanvasOrderSeedStrategy: Sendable, Equatable {
  case neighborBarycenter
  case currentPosition
  case documentOrder
}
