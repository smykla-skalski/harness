import HarnessMonitorKit
import SwiftUI

// Pill rule for the Reviews surface (2026-05-23):
// - `harnessControlPillGlass`        -> infrastructure signals (sync, count,
//                                       refresh-time, source).
// - `DashboardReviewStatusPill`      -> content signals (review state, check
//                                       state, attention, draft, labels).
// - `DashboardReviewMetricPill`      -> summary aggregates (Total / Ready /
//                                       Blocked counts).
// - `DashboardReviewAttentionSummary` -> page-level alert blocks only.
//
// `isQuiet` convention:
// - `isQuiet: true` (the default) is for attention badges, label chips, draft
//   chip, and any secondary status pill on a row.
// - `isQuiet: false` is reserved for the one primary status pill per row
//   (the status-line pill in `DashboardReviewStatusStrip`, "All checks
//   passed" / "N failing" check summary, "Cached" summary marker, and
//   `Live daemon` source label). Callers that need the louder weight must
//   pass `isQuiet: false` explicitly.
//
// Corner radii:
// - Tinted pills share `HarnessMonitorTheme.pillCornerRadius` (7).
// - Glass-capsule pills use `harnessControlPillGlass`'s own rounding.
// - `DashboardReviewAttentionSummary` is an alert block, not a pill; it
//   stays at 8pt to read as "alert chrome" distinct from the tinted-pill
//   family and the 12pt card chrome (`HarnessMonitorTheme.cornerRadiusSM`).

enum DashboardReviewsVisualMetrics {
  /// Forwards to `HarnessMonitorTheme.pillCornerRadius` so non-dashboard
  /// surfaces can share the same value through the theme. Kept here as a
  /// transitional alias; new code should prefer the theme constant.
  static let pillCornerRadius: CGFloat = HarnessMonitorTheme.pillCornerRadius
  static let reviewRowHorizontalPadding: CGFloat = 4
  static let reviewRowVerticalPadding: CGFloat = 14
  static let sectionMaxWidth: CGFloat = 940
}

enum DashboardReviewCheckTextCenterAlignment: AlignmentID {
  static func defaultValue(in context: ViewDimensions) -> CGFloat {
    context[VerticalAlignment.center]
  }
}

extension VerticalAlignment {
  static let dashboardReviewCheckTextCenter = VerticalAlignment(
    DashboardReviewCheckTextCenterAlignment.self
  )
}

struct DashboardReviewsSummaryStatStrip: View {
  let summary: ReviewsSummary
  let showsCachedResults: Bool
  let refreshDescription: String

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      HarnessMonitorWrapLayout(
        spacing: HarnessMonitorTheme.spacingSM,
        lineSpacing: HarnessMonitorTheme.spacingSM
      ) {
        DashboardReviewMetricPill(
          title: "Total", value: summary.total, tint: HarnessMonitorTheme.accent)
        DashboardReviewMetricPill(
          title: "Ready", value: summary.readyToMerge, tint: HarnessMonitorTheme.success)
        DashboardReviewMetricPill(
          title: "Review", value: summary.reviewRequired, tint: HarnessMonitorTheme.accent)
        DashboardReviewMetricPill(
          title: "Checks", value: summary.waitingOnChecks, tint: HarnessMonitorTheme.caution)
        DashboardReviewMetricPill(
          title: "Blocked", value: summary.blocked, tint: HarnessMonitorTheme.danger)
        if showsCachedResults {
          DashboardReviewStatusPill(
            label: "Cached",
            tint: HarnessMonitorTheme.secondaryInk,
            systemImage: "archivebox",
            isQuiet: false,
            help: "Results loaded from local cache, not the live daemon"
          )
        }
      }

      Label("Refresh interval \(refreshDescription)", systemImage: "clock.arrow.circlepath")
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .labelStyle(.titleAndIcon)
    }
  }
}

struct DashboardReviewStatusStrip: View {
  let item: ReviewItem

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
        DashboardReviewStatusPill(
          label: item.statusLabel,
          tint: item.statusTint,
          systemImage: item.requiresAttention ? nil : item.statusSystemImage,
          isQuiet: false
        )
        Text(item.statusSummarySentence)
          .scaledFont(.callout)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
      }

      HarnessMonitorWrapLayout(
        spacing: HarnessMonitorTheme.spacingSM,
        lineSpacing: HarnessMonitorTheme.spacingSM
      ) {
        if !(item.requiresAttention && item.reviewStatus == .approved) {
          DashboardReviewStatusPill(
            label: item.reviewStatus.label,
            tint: item.reviewStatus.tint,
            isQuiet: true
          )
        }
        DashboardReviewStatusPill(
          label: item.checkStatus.label,
          tint: item.checkStatus.tint,
          isQuiet: true
        )
        if item.policyBlocked {
          DashboardReviewStatusPill(
            label: "Policy blocked",
            tint: HarnessMonitorTheme.caution,
            systemImage: "hourglass",
            isQuiet: true
          )
        }
        if item.mergeable == .conflicting {
          DashboardReviewStatusPill(
            label: "Merge conflicts",
            tint: HarnessMonitorTheme.danger,
            systemImage: "arrow.triangle.merge",
            isQuiet: true,
            help: "Resolve merge conflicts before merging"
          )
        }
      }
    }
  }
}

struct DashboardReviewAttentionSummary: View {
  let item: ReviewItem

  private var tint: Color { item.attentionTint }
  private var primaryAttentionReason: DashboardReviewAttentionReason? {
    item.primaryAttentionReason
  }
  private var lineChangeAccessibilityValue: String {
    DashboardReviewInlineChangeStats.accessibilityLabel(
      additions: item.additions,
      deletions: item.deletions
    )
  }

  private var supplementaryReviewStatusLabel: String? {
    guard let primaryAttentionReason else {
      return item.reviewStatus.label
    }
    guard !(item.requiresAttention && item.reviewStatus == .approved) else { return nil }
    if case .changesRequested = primaryAttentionReason {
      return nil
    }
    return item.reviewStatus.label
  }

  private var showsCheckStatusChip: Bool {
    guard let primaryAttentionReason else { return true }
    switch primaryAttentionReason {
    case .requiredFailedChecks, .checksFailing:
      return false
    case .changesRequested, .policyBlocked, .mergeConflicts:
      return true
    }
  }

  private var showsPolicyBlockedChip: Bool {
    guard item.policyBlocked else { return false }
    guard let primaryAttentionReason else { return true }
    if case .policyBlocked = primaryAttentionReason {
      return false
    }
    return true
  }

  @ViewBuilder private var summaryChipsRow: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      if let supplementaryReviewStatusLabel {
        DashboardReviewStatusPill(
          label: supplementaryReviewStatusLabel,
          tint: item.reviewStatus.tint,
          isQuiet: true
        )
      }
      if showsCheckStatusChip {
        DashboardReviewStatusPill(
          label: item.checkStatus.label,
          tint: item.checkStatus.tint,
          isQuiet: true
        )
      }
      if showsPolicyBlockedChip {
        DashboardReviewStatusPill(
          label: "Policy blocked",
          tint: HarnessMonitorTheme.caution,
          systemImage: "hourglass",
          isQuiet: true
        )
      }
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  var body: some View {
    HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(tint)
        .imageScale(.medium)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
            Text(item.attentionTitle)
              .scaledFont(.caption.weight(.semibold))
              .foregroundStyle(HarnessMonitorTheme.ink)
              .fixedSize(horizontal: true, vertical: false)
            summaryChipsRow
          }
          VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
            Text(item.attentionTitle)
              .scaledFont(.caption.weight(.semibold))
              .foregroundStyle(HarnessMonitorTheme.ink)
            summaryChipsRow
          }
        }
        Text(item.attentionSentence)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(
      tint.opacity(0.10),
      in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(tint.opacity(0.34), lineWidth: 1)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(item.attentionTitle)
    .accessibilityValue("\(item.attentionSentence). \(lineChangeAccessibilityValue)")
  }
}

private enum DashboardReviewAttentionReason: Equatable {
  case requiredFailedChecks([String])
  case checksFailing
  case changesRequested
  case policyBlocked
  case mergeConflicts

  var title: String {
    switch self {
    case .requiredFailedChecks, .checksFailing:
      "Fix failing checks"
    case .changesRequested:
      "Address requested changes"
    case .policyBlocked:
      "Satisfy review policy"
    case .mergeConflicts:
      "Resolve merge conflicts"
    }
  }

  var tint: Color {
    switch self {
    case .policyBlocked:
      HarnessMonitorTheme.caution
    case .requiredFailedChecks, .checksFailing, .changesRequested, .mergeConflicts:
      HarnessMonitorTheme.danger
    }
  }

  var guidanceSentence: String {
    switch self {
    case .requiredFailedChecks(let names):
      let list = names.joined(separator: ", ")
      return list.isEmpty
        ? "Fix the failing required checks before merging."
        : "Fix the failing required checks before merging: \(list)."
    case .checksFailing:
      return "Fix the failing checks before merging."
    case .changesRequested:
      return "Address the requested changes before this pull request can move forward."
    case .policyBlocked:
      return "Satisfy the review policy before merging."
    case .mergeConflicts:
      return "Update the branch or resolve the conflicts before merging."
    }
  }

  var reasonSentence: String {
    switch self {
    case .requiredFailedChecks(let names):
      let list = names.joined(separator: ", ")
      return list.isEmpty
        ? "Required checks are failing."
        : "Required checks are failing: \(list)."
    case .checksFailing:
      return "Checks are failing."
    case .changesRequested:
      return "A reviewer requested changes."
    case .policyBlocked:
      return "Review policy is blocking merge."
    case .mergeConflicts:
      return "Merge conflicts must be resolved."
    }
  }
}

extension ReviewCheckStatus {
  var tint: Color {
    switch self {
    case .success:
      HarnessMonitorTheme.success
    case .failure:
      HarnessMonitorTheme.danger
    case .pending:
      HarnessMonitorTheme.caution
    case .none, .unknown:
      HarnessMonitorTheme.secondaryInk
    }
  }
}

extension ReviewItem {
  fileprivate var primaryAttentionReason: DashboardReviewAttentionReason? {
    attentionReasons.first
  }

  var attentionTint: Color {
    primaryAttentionReason?.tint ?? HarnessMonitorTheme.caution
  }

  var statusSummarySentence: String {
    "\(reviewStatus.statusSentenceFragment), \(checkStatus.statusSentenceFragment)."
  }

  var attentionTitle: String {
    primaryAttentionReason?.title ?? "Needs attention"
  }

  var attentionSentence: String {
    guard let primaryReason = primaryAttentionReason else {
      return "No attention reason is reported"
    }

    let segments =
      ([primaryReason.guidanceSentence]
      + attentionReasons
      .dropFirst()
      .map(\.reasonSentence))
      .map(Self.trimmingTrailingPeriod)
    return segments.joined(separator: ". ")
  }

  private var attentionReasons: [DashboardReviewAttentionReason] {
    var reasons: [DashboardReviewAttentionReason] = []
    if hasRequiredFailedChecks {
      reasons.append(.requiredFailedChecks(requiredFailedCheckNames))
    } else if checkStatus == .failure {
      reasons.append(.checksFailing)
    }
    if reviewStatus == .changesRequested {
      reasons.append(.changesRequested)
    }
    if policyBlocked {
      reasons.append(.policyBlocked)
    }
    if mergeable == .conflicting {
      reasons.append(.mergeConflicts)
    }
    return reasons
  }

  private static func trimmingTrailingPeriod(_ value: String) -> String {
    if value.hasSuffix(".") {
      return String(value.dropLast())
    }
    return value
  }
}
