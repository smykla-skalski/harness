import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

/// Replay section of the confidence panel. Collapsed by default so it does not
/// crowd the decision matrix. Replays the active draft over the recorded
/// real-decision feed and lists, per recorded decision, what history enforced
/// versus what the draft would now decide - the answer to "would my edits change
/// real outcomes". The Load/Refresh action sits in the header so it works while
/// the section is collapsed, and a loaded result is kept (dimmed and flagged)
/// when the draft moves on rather than cleared, so the comparison survives an
/// edit. The rows are a resolved value, so the section skips its body when only
/// the spinner flips.
struct PolicyCanvasReplayInspector: View {
  let rows: [PolicyCanvasReplayRowModel]
  let summary: PolicyCanvasReplaySummary?
  let isLoading: Bool
  /// True when a result is loaded but the draft has since changed, so the
  /// comparison on screen no longer reflects the current draft.
  let isStale: Bool
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
              .foregroundStyle(summaryTint)
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
      .accessibilityLabel(accessibilityLabel)
      .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
      .accessibilityHint("Compare your draft against recorded traffic")

      // Lives in the header, not the body, so a collapsed Replay can still be
      // loaded or refreshed without first expanding the section.
      loadButton
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private var loadButton: some View {
    Button(summary == nil ? "Load" : "Refresh", action: loadReplay)
      .scaledFont(.caption.weight(.semibold))
      .harnessActionButtonStyle(variant: .bordered, tint: loadButtonTint)
      .controlSize(.small)
      .disabled(isLoading)
      .help("Replay the draft over the recorded decision feed")
      .accessibilityHint(isStale ? "Draft changed - refresh to update the comparison" : "")
      .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasReplayLoadButton)
  }

  @ViewBuilder private var content: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Compares your draft against decisions made on real recorded traffic")
        .scaledFont(.caption2)
        .foregroundStyle(PolicyCanvasVisualStyle.tertiaryText)
        .fixedSize(horizontal: false, vertical: true)

      if rows.isEmpty {
        if let emptyMessage {
          Text(emptyMessage)
            .scaledFont(.caption)
            .foregroundStyle(PolicyCanvasVisualStyle.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        if isStale {
          staleHint
        }
        // Scrolls within the section's share of the pane, like Scenarios, so an
        // expanded Replay shares the available room instead of running off the
        // bottom of the pane.
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
              PolicyCanvasReplayRow(row: row, focusDecision: focusDecision)
            }
          }
        }
        .frame(maxHeight: .infinity)
        // Dim a stale comparison so an old draft verdict is never read as current.
        .opacity(isStale ? 0.5 : 1)
      }
    }
    .padding(.horizontal, 12)
    .padding(.bottom, 10)
  }

  private var staleHint: some View {
    Label(
      "Draft changed since this replay - refresh to update",
      systemImage: "exclamationmark.triangle.fill"
    )
    .scaledFont(.caption2)
    .foregroundStyle(PolicyCanvasVisualStyle.warningTint)
    .fixedSize(horizontal: false, vertical: true)
  }

  /// Amber while a loaded result is stale so the count flags it even when the
  /// section is collapsed and the rows are hidden.
  private var summaryTint: Color {
    isStale ? PolicyCanvasVisualStyle.warningTint : PolicyCanvasVisualStyle.tertiaryText
  }

  /// Stale invites a refresh, a never-loaded section invites a first load, and a
  /// current result keeps the refresh quiet so it does not compete with the data.
  private var loadButtonTint: Color {
    if isStale {
      return PolicyCanvasVisualStyle.warningTint
    }
    return summary == nil
      ? PolicyCanvasVisualStyle.readyTint : PolicyCanvasVisualStyle.secondaryText
  }

  private var emptyMessage: String? {
    if isLoading {
      return "Replaying recorded decisions\u{2026}"
    }
    if summary == nil {
      // The caption plus the header Load button already say what to do; a third
      // restatement here is the redundancy this section was dinged for.
      return nil
    }
    return "No decisions recorded yet. Replay fills in once a live policy sees real traffic"
  }

  private var accessibilityLabel: String {
    guard let summary else {
      return "Replay, not yet loaded"
    }
    let base = "Replay, \(summary.changedCount) of \(summary.sampleSize) decisions changed"
    return isStale ? base + ", stale, draft changed since this replay" : base
  }
}
