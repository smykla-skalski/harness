import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

/// Bottom-right canvas affordance mirroring `PolicyCanvasViewModel.saveActivity`.
/// A small spinner + "Saving…" while a debounced or manual save is queued or in
/// flight; a brief check on success; an error marker on reject. Hidden at rest.
/// The detailed reject/recovery flow stays on the existing toast + sticky
/// affordance — this pill is only a lightweight progress cue.
///
/// Self-gating: the view is always mounted in the corner cluster and renders
/// nothing when `idle`, so the insertion/removal transition can play. Reduce-
/// motion collapses the slide to a plain opacity fade via `PolicyCanvasMotion`.
struct PolicyCanvasSaveStatusPill: View {
  let activity: PolicyCanvasSaveActivity
  @Environment(\.policyCanvasReducedMotion)
  private var canvasReducedMotion
  @Environment(\.accessibilityReduceMotion)
  private var systemReduceMotion

  private var reducedMotion: Bool {
    canvasReducedMotion ?? systemReduceMotion
  }

  var body: some View {
    let presentation = activity.presentation
    Group {
      if presentation.isVisible {
        pill(presentation)
          .transition(transition)
      }
    }
    .animation(PolicyCanvasMotion.saveStatus(reducedMotion: reducedMotion), value: activity)
  }

  private func pill(_ presentation: PolicyCanvasSaveStatusPresentation) -> some View {
    HStack(spacing: 6) {
      leadingGlyph(presentation)
      Text(presentation.label)
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .harnessControlPillGlass(tint: HarnessMonitorTheme.controlBorder)
    .shadow(color: Color.black.opacity(0.12), radius: 4, y: 1)
    // `.ignore` (not `.combine`): the spinner/symbol carry their own
    // busy/decorative semantics that would muddy the announcement. Collapse to
    // one element with an explicit label. Durable spoken status still flows
    // through the canvas status line's polite live region, so the pill does not
    // double-announce.
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(presentation.accessibilityLabel)
  }

  @ViewBuilder
  private func leadingGlyph(_ presentation: PolicyCanvasSaveStatusPresentation) -> some View {
    if presentation.showsSpinner {
      HarnessMonitorSpinner(size: 14, tint: tint(for: presentation.role))
    } else if let symbolName = presentation.symbolName {
      Image(systemName: symbolName)
        .font(.caption)
        .foregroundStyle(tint(for: presentation.role))
    }
  }

  private func tint(for role: PolicyCanvasSaveStatusPresentation.Role) -> Color {
    switch role {
    case .progress:
      .secondary
    case .success:
      .green
    case .failure:
      .orange
    }
  }

  private var transition: AnyTransition {
    if reducedMotion {
      return .opacity
    }
    return .opacity.combined(with: .move(edge: .trailing))
  }
}
