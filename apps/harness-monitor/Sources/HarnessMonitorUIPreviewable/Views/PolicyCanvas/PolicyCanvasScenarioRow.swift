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
            Text(primaryName)
              .scaledFont(.caption.weight(.medium))
              .lineLimit(1)
              .foregroundStyle(PolicyCanvasVisualStyle.primaryText)
            if showsActionSubtitle {
              Text(row.actionTitle)
                .scaledFont(.caption2)
                .lineLimit(1)
                .foregroundStyle(PolicyCanvasVisualStyle.tertiaryText)
            }
          }
          Spacer(minLength: 8)
          PolicyCanvasVerdictPill(verdict: row.verdict)
            .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
      }
      .harnessPlainButtonStyle()
      .accessibilityElement(children: .combine)
      .accessibilityLabel(accessibilityLabel)
      .accessibilityHint(row.visitedNodeIds.isEmpty ? "" : "Traces this scenario on the canvas")

      Button {
        editScenario(row.id)
      } label: {
        Image(systemName: "pencil")
          .scaledFont(.caption2)
          .foregroundStyle(PolicyCanvasVisualStyle.tertiaryText)
      }
      .harnessPlainButtonStyle()
      .accessibilityLabel("Edit scenario \(primaryName)")

      Button {
        deleteScenario(row.id)
      } label: {
        Image(systemName: "trash")
          .scaledFont(.caption2)
          .foregroundStyle(PolicyCanvasVisualStyle.tertiaryText)
      }
      .harnessPlainButtonStyle()
      .accessibilityLabel("Delete scenario \(primaryName)")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
  }

  /// Announce the navigation for VoiceOver, then trace on the canvas - the
  /// visible effect lands elsewhere, so without this the tap is silent.
  private func trace() {
    if !row.visitedNodeIds.isEmpty {
      AccessibilityNotification.Announcement("Tracing \(primaryName) on the canvas").post()
    }
    focusDecision(row.visitedNodeIds)
  }

  /// Seeded scenarios are named after their action (the raw "sync" token), which
  /// just repeats the proper-cased action title below it. When the name is only a
  /// case or separator variant of the action, show the clean action title alone.
  private var matchesAction: Bool {
    let name = row.name.replacingOccurrences(of: "_", with: " ")
    return name.caseInsensitiveCompare(row.actionTitle) == .orderedSame
  }

  private var primaryName: String {
    matchesAction || row.name.isEmpty ? row.actionTitle : row.name
  }

  private var showsActionSubtitle: Bool {
    !matchesAction && !row.name.isEmpty
  }

  private var accessibilityLabel: String {
    showsActionSubtitle
      ? "\(row.name), \(row.actionTitle): \(row.verdict.label)"
      : "\(row.actionTitle): \(row.verdict.label)"
  }
}
