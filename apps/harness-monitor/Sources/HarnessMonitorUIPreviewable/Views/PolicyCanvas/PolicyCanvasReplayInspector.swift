import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

/// Replay section of the confidence panel. Collapsed by default so it does not
/// crowd the decision matrix. Replays the active draft over the recorded
/// real-decision feed and lists, per recorded decision, what history enforced
/// versus what the draft would now decide - the answer to "would my edits change
/// real outcomes". The Load/Refresh action lives inside the expanded body so it
/// never appears before the results it produces. The rows are a resolved value,
/// so the section skips its body when only the spinner flips.
struct PolicyCanvasReplayInspector: View {
  let rows: [PolicyCanvasReplayRowModel]
  let summary: PolicyCanvasReplaySummary?
  let isLoading: Bool
  let focusDecision: @MainActor ([String]) -> Void
  let loadReplay: @MainActor () -> Void

  @State private var isExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Rectangle()
        .fill(PolicyCanvasVisualStyle.separator)
        .frame(height: 1)
      header
      if isExpanded {
        content
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasReplayInspector)
  }

  private var header: some View {
    Button {
      isExpanded.toggle()
    } label: {
      HStack(spacing: 6) {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
          .scaledFont(.caption2.weight(.semibold))
        Text("Replay")
          .scaledFont(.caption.weight(.semibold))
        if let summary {
          Text("\(summary.changedCount)/\(summary.sampleSize)")
            .scaledFont(.caption2)
            .foregroundStyle(PolicyCanvasVisualStyle.tertiaryText)
        }
        if isLoading {
          ProgressView().controlSize(.mini)
        }
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    .accessibilityHint("Compares your draft against decisions on real recorded traffic")
  }

  @ViewBuilder private var content: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Compares your draft against decisions made on real recorded traffic.")
        .scaledFont(.caption2)
        .foregroundStyle(PolicyCanvasVisualStyle.tertiaryText)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 0) {
        Button(summary == nil ? "Load" : "Refresh", action: loadReplay)
          .scaledFont(.caption2.weight(.semibold))
          .buttonStyle(.borderless)
          .foregroundStyle(PolicyCanvasVisualStyle.readyTint)
          .disabled(isLoading)
          .help("Replay the draft over the recorded decision feed")
          .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasReplayLoadButton)
        Spacer(minLength: 0)
      }

      if rows.isEmpty {
        Text(emptyMessage)
          .scaledFont(.caption)
          .foregroundStyle(PolicyCanvasVisualStyle.tertiaryText)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
              PolicyCanvasReplayRow(row: row, focusDecision: focusDecision)
            }
          }
        }
        .frame(maxHeight: 180)
      }
    }
    .padding(.horizontal, 12)
    .padding(.bottom, 10)
  }

  private var emptyMessage: String {
    if isLoading {
      return "Replaying recorded decisions\u{2026}"
    }
    if summary == nil {
      return "Load a replay to compare the draft against recorded decisions."
    }
    return "No decisions recorded yet. Replay fills in once a live policy sees real traffic."
  }

  private var accessibilityLabel: String {
    guard let summary else {
      return "Replay"
    }
    return "Replay, \(summary.changedCount) of \(summary.sampleSize) decisions changed"
  }
}
