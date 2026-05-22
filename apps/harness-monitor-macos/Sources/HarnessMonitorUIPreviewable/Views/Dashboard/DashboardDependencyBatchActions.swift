import HarnessMonitorKit
import SwiftUI

enum DashboardDependencyBatchActionKind: String, CaseIterable, Identifiable {
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

  func canRun(_ item: DependencyUpdateItem) -> Bool {
    switch self {
    case .approve: item.canAttemptManualApproval
    case .merge: item.canAttemptManualMerge
    case .rerunChecks: item.canAttemptRerunChecks
    case .auto: item.canRunAutoMode
    case .label: item.canAddDependencyLabel
    }
  }

  func unavailableReason(for item: DependencyUpdateItem) -> String {
    let reason =
      switch self {
      case .approve:
        DashboardDependenciesDisabledReason.approveReason(for: [item])
      case .merge:
        DashboardDependenciesDisabledReason.mergeReason(for: [item])
      case .rerunChecks:
        DashboardDependenciesDisabledReason.rerunReason(for: [item])
      case .auto:
        DashboardDependenciesDisabledReason.autoReason(for: [item])
      case .label:
        DashboardDependenciesDisabledReason.labelReason(for: [item])
      }
    return reason ?? "Already handled"
  }
}

struct DashboardDependencyBatchSkippedReason: Equatable, Identifiable {
  let reason: String
  let count: Int

  var id: String { reason }
}

struct DashboardDependencyBatchEligibility: Equatable, Identifiable {
  let kind: DashboardDependencyBatchActionKind
  let actionableCount: Int
  let skippedReasons: [DashboardDependencyBatchSkippedReason]

  var id: DashboardDependencyBatchActionKind { kind }

  var skippedCount: Int {
    skippedReasons.reduce(0) { $0 + $1.count }
  }

  var totalCount: Int {
    actionableCount + skippedCount
  }

  static func preview(
    kind: DashboardDependencyBatchActionKind,
    items: [DependencyUpdateItem]
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
        DashboardDependencyBatchSkippedReason(reason: reason, count: count)
      }
      .sorted { lhs, rhs in
        if lhs.count != rhs.count { return lhs.count > rhs.count }
        return lhs.reason.localizedStandardCompare(rhs.reason) == .orderedAscending
      }
    return Self(kind: kind, actionableCount: actionableCount, skippedReasons: skippedReasons)
  }

  static func previews(for items: [DependencyUpdateItem]) -> [Self] {
    DashboardDependencyBatchActionKind.allCases.map { kind in
      preview(kind: kind, items: items)
    }
  }
}

struct DashboardDependencyBatchConfirmation: Equatable, Identifiable {
  enum Action: Equatable {
    case merge
    case auto
  }

  let id: String
  let action: Action
  let pullRequestIDs: [String]
  let title: String
  let message: String
  let confirmTitle: String

  static func merge(
    items: [DependencyUpdateItem],
    mergeMethod: TaskBoardGitHubMergeMethod
  ) -> Self {
    let eligibility = DashboardDependencyBatchEligibility.preview(kind: .merge, items: items)
    return Self(
      id: "merge:\(items.map(\.pullRequestID).joined(separator: ","))",
      action: .merge,
      pullRequestIDs: items.map(\.pullRequestID),
      title: "Confirm merge",
      message:
        "Merge \(eligibility.actionableCount) of \(items.count) selected pull requests "
        + "using \(mergeMethod.title).\(skippedSummary(for: eligibility))",
      confirmTitle: "Merge \(pullRequestLabel(eligibility.actionableCount))"
    )
  }

  static func auto(
    items: [DependencyUpdateItem],
    mergeMethod: TaskBoardGitHubMergeMethod
  ) -> Self {
    let eligibility = DashboardDependencyBatchEligibility.preview(kind: .auto, items: items)
    return Self(
      id: "auto:\(items.map(\.pullRequestID).joined(separator: ","))",
      action: .auto,
      pullRequestIDs: items.map(\.pullRequestID),
      title: "Confirm auto mode",
      message:
        "Run auto mode on \(eligibility.actionableCount) of \(items.count) selected pull "
        + "requests using \(mergeMethod.title).\(skippedSummary(for: eligibility))",
      confirmTitle: "Run Auto on \(pullRequestLabel(eligibility.actionableCount))"
    )
  }

  private static func pullRequestLabel(_ count: Int) -> String {
    count == 1 ? "1 Pull Request" : "\(count) Pull Requests"
  }

  private static func skippedSummary(
    for eligibility: DashboardDependencyBatchEligibility
  ) -> String {
    guard eligibility.skippedCount > 0 else { return "" }
    let reasons = eligibility.skippedReasons.prefix(2)
      .map { "\($0.count) \($0.reason)" }
      .joined(separator: "; ")
    return " Skipping \(eligibility.skippedCount): \(reasons)."
  }
}

struct DashboardDependencyBatchEligibilityPreview: View {
  let items: [DependencyUpdateItem]

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Batch eligibility")
        .scaledFont(.headline.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.ink)
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        ForEach(DashboardDependencyBatchEligibility.previews(for: items)) { preview in
          DashboardDependencyBatchEligibilityRow(preview: preview)
        }
      }
    }
  }
}

private struct DashboardDependencyBatchEligibilityRow: View {
  let preview: DashboardDependencyBatchEligibility

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        Label(preview.kind.title, systemImage: preview.kind.systemImage)
          .scaledFont(.callout.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.ink)
        Spacer(minLength: HarnessMonitorTheme.spacingSM)
        DashboardDependencyStatusPill(
          label: "\(preview.actionableCount) run",
          tint: preview.actionableCount > 0
            ? HarnessMonitorTheme.success
            : HarnessMonitorTheme.secondaryInk,
          isQuiet: preview.actionableCount == 0
        )
        if preview.skippedCount > 0 {
          DashboardDependencyStatusPill(
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
