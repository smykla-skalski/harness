import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

/// Replay section of the confidence panel. Collapsed by default so it does not
/// crowd the decision matrix. Replays the active draft over the recorded
/// real-decision feed and lists, per recorded decision, what history enforced
/// versus what the draft would now decide - the answer to "would my edits change
/// real outcomes". The rows are a resolved value, so the section skips its body
/// when only the spinner flips.
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
    HStack(spacing: 8) {
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
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
      .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)

      Spacer(minLength: 8)

      Button(summary == nil ? "Load" : "Refresh", action: loadReplay)
        .scaledFont(.caption2.weight(.semibold))
        .buttonStyle(.borderless)
        .foregroundStyle(PolicyCanvasVisualStyle.readyTint)
        .disabled(isLoading)
        .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasReplayLoadButton)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  @ViewBuilder private var content: some View {
    if rows.isEmpty {
      Text(emptyMessage)
        .scaledFont(.caption)
        .foregroundStyle(PolicyCanvasVisualStyle.tertiaryText)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(rows) { row in
            PolicyCanvasReplayRow(row: row, focusDecision: focusDecision)
          }
        }
      }
      .frame(maxHeight: 180)
      .padding(.bottom, 6)
    }
  }

  private var emptyMessage: String {
    if isLoading {
      return "Replaying recorded decisions"
    }
    if summary == nil {
      return "Load a replay to compare the draft against recorded decisions"
    }
    return "No decisions recorded yet. Replay fills in once a live policy sees real traffic."
  }
}
