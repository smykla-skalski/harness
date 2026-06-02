import SwiftUI
import HarnessMonitorPolicyCanvasAlgorithms

extension PolicyCanvasNodeKind {
  var accentColor: Color {
    PolicyCanvasVisualStyle.nodeTint(for: self)
  }
}

extension PolicyCanvasGroupTone {
  var color: Color {
    PolicyCanvasVisualStyle.groupTint(for: self)
  }
}
