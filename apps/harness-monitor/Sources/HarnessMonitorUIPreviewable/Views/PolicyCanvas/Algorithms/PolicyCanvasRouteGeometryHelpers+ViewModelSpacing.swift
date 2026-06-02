import SwiftUI
import HarnessMonitorPolicyCanvasAlgorithms

@MainActor
func policyCanvasRouteMinimumSpacing(
  viewModel: PolicyCanvasViewModel,
  edge: PolicyCanvasEdge,
  route: PolicyCanvasEdgeRoute
) -> CGFloat {
  policyCanvasRouteMinimumSpacing(
    edge: edge,
    route: route,
    sourceSpacingBySide: Dictionary(
      uniqueKeysWithValues: PolicyCanvasPortSide.allSides.map { side in
        (side, viewModel.portSpacing(for: edge.source, side: side))
      }
    ),
    targetSpacingBySide: Dictionary(
      uniqueKeysWithValues: PolicyCanvasPortSide.allSides.map { side in
        (side, viewModel.portSpacing(for: edge.target, side: side))
      }
    )
  )
}
