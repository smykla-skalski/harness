import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

extension PolicyCanvasEdgeKind {
  var accentColor: Color {
    PolicyCanvasVisualStyle.edgeTint(for: self)
  }
}
