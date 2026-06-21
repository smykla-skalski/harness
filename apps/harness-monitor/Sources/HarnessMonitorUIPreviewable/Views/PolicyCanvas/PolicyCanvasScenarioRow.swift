import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

/// One scenario inspector row: name + action on the leading edge, the verdict
/// pill, and a trailing delete. Tapping the leading area lights the decision's
/// path via the shared focus-decision closure. The delete is a sibling button
/// (never nested inside the row button) so its hit area stays its own.
struct PolicyCanvasScenarioRow: View {
  let row: PolicyCanvasScenarioRowModel
  let focusDecision: @MainActor ([String]) -> Void
  let editScenario: @MainActor (String) -> Void
  let deleteScenario: @MainActor (String) -> Void

  var body: some View {
    HStack(spacing: 8) {
      Button(action: trace) {
        HStack(spacing: 8) {
          VStack(alignment: .leading, spacing: 2) {
            Text(row.name)
              .scaledFont(.caption.weight(.medium))
              .lineLimit(1)
              .foregroundStyle(PolicyCanvasVisualStyle.primaryText)
            Text(row.actionTitle)
              .scaledFont(.caption2)
              .lineLimit(1)
              .foregroundStyle(PolicyCanvasVisualStyle.tertiaryText)
          }
          Spacer(minLength: 8)
          PolicyCanvasVerdictPill(verdict: row.verdict)
        }
        .contentShape(Rectangle())
      }
      .harnessPlainButtonStyle()
      .accessibilityElement(children: .combine)
      .accessibilityLabel("\(row.name), \(row.actionTitle): \(row.verdict.label)")
      .accessibilityHint(row.visitedNodeIds.isEmpty ? "" : "Traces this scenario on the canvas")

      Button {
        editScenario(row.id)
      } label: {
        Image(systemName: "pencil")
          .scaledFont(.caption2)
          .foregroundStyle(PolicyCanvasVisualStyle.tertiaryText)
      }
      .harnessPlainButtonStyle()
      .accessibilityLabel("Edit scenario \(row.name)")

      Button {
        deleteScenario(row.id)
      } label: {
        Image(systemName: "trash")
          .scaledFont(.caption2)
          .foregroundStyle(PolicyCanvasVisualStyle.tertiaryText)
      }
      .harnessPlainButtonStyle()
      .accessibilityLabel("Delete scenario \(row.name)")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
  }

  /// Announce the navigation for VoiceOver, then trace on the canvas - the
  /// visible effect lands elsewhere, so without this the tap is silent.
  private func trace() {
    if !row.visitedNodeIds.isEmpty {
      AccessibilityNotification.Announcement("Tracing \(row.name) on the canvas").post()
    }
    focusDecision(row.visitedNodeIds)
  }
}
