import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

/// Always-running decision matrix: how the current draft resolves each policy
/// action under the latest simulation. Rows arrive as a resolved value so the
/// matrix only redraws when the decisions actually change, and each row is a
/// separate struct so a tap never invalidates its siblings.
struct PolicyCanvasDecisionMatrixView: View {
  let rows: [PolicyCanvasDecisionMatrixRowModel]
  /// True while a confidence simulation is in flight, so the header can show a
  /// spinner now that the auto-runner replaced the manual Simulate button.
  let isEvaluating: Bool
  let focusDecision: @MainActor ([String]) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header

      if rows.isEmpty {
        emptyState
      } else {
        caption
        // No inner scroll or fixed cap: the confidence pane owns one scroll view,
        // so the full simulation flows with scenarios and replay instead of
        // clipping past ~220pt while the tall pane has room to spare.
        VStack(spacing: 6) {
          ForEach(rows) { row in
            PolicyCanvasDecisionMatrixRow(model: row, focusDecision: focusDecision)
          }
        }
        // Dim the prior verdicts while a fresh simulation is in flight so a
        // stale row is never read as current.
        .opacity(isEvaluating ? 0.55 : 1)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(PolicyCanvasVisualStyle.dashboardHostBackground)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(PolicyCanvasVisualStyle.separator)
        .frame(height: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasDecisionMatrix)
  }

  private var header: some View {
    HStack(spacing: 8) {
      Label("Decisions", systemImage: "checklist")
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)

      if isEvaluating {
        HarnessMonitorSpinner(size: 12, tint: PolicyCanvasVisualStyle.secondaryText)
      }

      Spacer(minLength: 0)

      if !rows.isEmpty {
        Text(summary)
          .scaledFont(.caption2.weight(.medium))
          .foregroundStyle(PolicyCanvasVisualStyle.tertiaryText)
          .help(
            "Gated actions need a human, consensus, or dry run, or are denied - "
              + "they will not run automatically."
          )
      }
    }
  }

  private var caption: some View {
    Text(
      "Read-only preview of how your draft decides each action. "
        + "Tap a row to trace it on the canvas."
    )
    .scaledFont(.caption2)
    .foregroundStyle(PolicyCanvasVisualStyle.tertiaryText)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var emptyState: some View {
    Text(
      isEvaluating
        ? "Evaluating how each action resolves\u{2026}"
        : "Edit the policy to preview how each action will be decided."
    )
    .scaledFont(.caption)
    .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var summary: String {
    let allowed = rows.filter { $0.verdict == .allow }.count
    let gated = rows.count - allowed
    return "\(allowed) allow \u{00b7} \(gated) gated"
  }
}

extension PolicyCanvasDecisionVerdict {
  var tone: PolicyCanvasWorkflowTone {
    switch self {
    case .allow:
      return .ready
    case .deny:
      return .blocked
    case .needsHuman, .consensus, .unknown:
      return .warning
    case .dryRun:
      return .active
    }
  }

  var systemImage: String {
    switch self {
    case .allow:
      return "checkmark.circle.fill"
    case .deny:
      return "xmark.octagon.fill"
    case .needsHuman:
      return "person.fill.questionmark"
    case .consensus:
      return "person.3.fill"
    case .dryRun:
      return "play.slash.fill"
    case .unknown:
      return "questionmark.circle.fill"
    }
  }
}
