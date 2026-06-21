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

  /// The last row the user traced, kept so the panel holds a persistent marker
  /// of which decision is shown on the canvas - the tap effect lands elsewhere,
  /// so without this the user has nothing to reorient against.
  @State private var activeRowID: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
        .padding(.horizontal, 14)

      if rows.isEmpty {
        emptyState
          .padding(.horizontal, 14)
      } else {
        caption
          .padding(.horizontal, 14)
        // Each list section scrolls within its share of the pane height so the
        // 13-row matrix shares space with the scenario and replay sections
        // instead of pushing them (and the Replay anchor) below the fold. The
        // scroll view spans the section full-bleed and the rows carry the inset,
        // so a focused row's keyboard ring clears the scroll clip on every edge
        // instead of being sliced off at the top or sides.
        ScrollView {
          VStack(spacing: 6) {
            ForEach(rows) { row in
              PolicyCanvasDecisionMatrixRow(
                model: row,
                isActive: row.id == activeRowID,
                focusDecision: { visitedNodeIds in
                  activeRowID = row.id
                  focusDecision(visitedNodeIds)
                }
              )
            }
          }
          .padding(.horizontal, 14)
          .padding(.vertical, 4)
        }
        .frame(maxHeight: .infinity)
        // Dim the prior verdicts while a fresh simulation is in flight so a
        // stale row is never read as current.
        .opacity(isEvaluating ? 0.55 : 1)
      }
    }
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
          .lineLimit(1)
      }
    }
  }

  private var caption: some View {
    Text(
      "Read-only preview of how your draft decides each action. "
        + "Tap a row to trace it on the canvas"
    )
    .scaledFont(.caption2)
    .foregroundStyle(PolicyCanvasVisualStyle.tertiaryText)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var emptyState: some View {
    Text(
      isEvaluating
        ? "Evaluating how each action resolves\u{2026}"
        : "Edit the policy to preview how each action will be decided"
    )
    .scaledFont(.caption)
    .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var summary: String {
    // Break the verdicts out instead of flattening every non-allow into one
    // "gated" count - a deny and a dry run are operationally nothing alike.
    let order: [(PolicyCanvasDecisionVerdict, String)] = [
      (.allow, "allow"),
      (.deny, "deny"),
      (.needsHuman, "needs human"),
      (.consensus, "consensus"),
      (.dryRun, "dry run"),
    ]
    return
      order
      .compactMap { verdict, label in
        let count = rows.filter { $0.verdict == verdict }.count
        return count > 0 ? "\(count) \(label)" : nil
      }
      .joined(separator: " \u{00b7} ")
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
