import HarnessMonitorKit
import SwiftUI

enum DashboardReviewBatchActionKind: String, CaseIterable, Identifiable {
  case approve
  case merge
  case rerunChecks
  case auto
  case label

  var id: String { rawValue }

  var title: String {
    switch self {
    case .approve: "Approve"
    case .merge: "Merge"
    case .rerunChecks: "Rerun"
    case .auto: "Auto"
    case .label: "Label"
    }
  }

  var systemImage: String {
    switch self {
    case .approve: "checkmark.seal"
    case .merge: "arrow.triangle.merge"
    case .rerunChecks: "arrow.clockwise.circle"
    case .auto: "bolt"
    case .label: "tag"
    }
  }

  func canRun(_ item: ReviewItem) -> Bool {
    switch self {
    case .approve: item.canAttemptManualApproval
    case .merge: item.canAttemptManualMerge
    case .rerunChecks: item.canAttemptRerunChecks
    case .auto: item.canRunAutoMode
    case .label: item.canAddReviewLabel
    }
  }

  func unavailableReason(for item: ReviewItem) -> String {
    let reason =
      switch self {
      case .approve:
        DashboardReviewsDisabledReason.approveReason(for: [item])
      case .merge:
        DashboardReviewsDisabledReason.mergeReason(for: [item])
      case .rerunChecks:
        DashboardReviewsDisabledReason.rerunReason(for: [item])
      case .auto:
        DashboardReviewsDisabledReason.autoReason(for: [item])
      case .label:
        DashboardReviewsDisabledReason.labelReason(for: [item])
      }
    return reason ?? "Already handled"
  }
}

struct DashboardReviewBatchSkippedReason: Equatable, Identifiable {
  let reason: String
  let count: Int

  var id: String { reason }
}

struct DashboardReviewBatchEligibility: Equatable, Identifiable {
  let kind: DashboardReviewBatchActionKind
  let actionableCount: Int
  let skippedReasons: [DashboardReviewBatchSkippedReason]

  var id: DashboardReviewBatchActionKind { kind }

  var skippedCount: Int {
    skippedReasons.reduce(0) { $0 + $1.count }
  }

  var totalCount: Int {
    actionableCount + skippedCount
  }

  static func preview(
    kind: DashboardReviewBatchActionKind,
    items: [ReviewItem]
  ) -> Self {
    var skippedCounts: [String: Int] = [:]
    var actionableCount = 0
    for item in items {
      if kind.canRun(item) {
        actionableCount += 1
      } else {
        skippedCounts[kind.unavailableReason(for: item), default: 0] += 1
      }
    }
    let skippedReasons =
      skippedCounts
      .map { reason, count in
        DashboardReviewBatchSkippedReason(reason: reason, count: count)
      }
      .sorted { lhs, rhs in
        if lhs.count != rhs.count { return lhs.count > rhs.count }
        return lhs.reason.localizedStandardCompare(rhs.reason) == .orderedAscending
      }
    return Self(kind: kind, actionableCount: actionableCount, skippedReasons: skippedReasons)
  }

  static func previews(for items: [ReviewItem]) -> [Self] {
    DashboardReviewBatchActionKind.allCases.map { kind in
      preview(kind: kind, items: items)
    }
  }
}

struct DashboardReviewBatchEligibilityPreview: View {
  let items: [ReviewItem]

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Batch eligibility")
        .scaledFont(.headline.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.ink)
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        ForEach(DashboardReviewBatchEligibility.previews(for: items)) { preview in
          DashboardReviewBatchEligibilityRow(preview: preview)
        }
      }
    }
  }
}

private struct DashboardReviewBatchEligibilityRow: View {
  let preview: DashboardReviewBatchEligibility

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        Label(preview.kind.title, systemImage: preview.kind.systemImage)
          .scaledFont(.callout.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.ink)
        Spacer(minLength: HarnessMonitorTheme.spacingSM)
        DashboardReviewStatusPill(
          label: "\(preview.actionableCount) run",
          tint: preview.actionableCount > 0
            ? HarnessMonitorTheme.success
            : HarnessMonitorTheme.secondaryInk,
          isQuiet: preview.actionableCount == 0
        )
        if preview.skippedCount > 0 {
          DashboardReviewStatusPill(
            label: "\(preview.skippedCount) skipped",
            tint: HarnessMonitorTheme.caution,
            isQuiet: true
          )
        }
      }
      ForEach(preview.skippedReasons.prefix(2)) { skipped in
        Text("\(skipped.count) skipped: \(skipped.reason)")
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(2)
      }
    }
  }
}
