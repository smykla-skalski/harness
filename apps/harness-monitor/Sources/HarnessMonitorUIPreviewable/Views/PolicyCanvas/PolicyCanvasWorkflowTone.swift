import SwiftUI

/// Tone ramp for the always-on policy-canvas status surfaces - the live anchor
/// badge and the confidence panel header. Maps a semantic state to the shared
/// `PolicyCanvasVisualStyle` tints plus the low-opacity background/border the
/// chips use. Relocated next to `PolicyCanvasVisualStyle` in the redesign so the
/// confidence surfaces reuse it without the deleted workflow-status machinery.
enum PolicyCanvasWorkflowTone {
  case ready
  case warning
  case blocked
  case active

  var tint: Color {
    switch self {
    case .ready:
      return PolicyCanvasVisualStyle.readyTint
    case .warning:
      return PolicyCanvasVisualStyle.warningTint
    case .blocked:
      return PolicyCanvasVisualStyle.blockedTint
    case .active:
      return PolicyCanvasVisualStyle.activeTint
    }
  }

  var background: Color {
    tint.opacity(0.08)
  }

  var border: Color {
    tint.opacity(0.18)
  }
}
