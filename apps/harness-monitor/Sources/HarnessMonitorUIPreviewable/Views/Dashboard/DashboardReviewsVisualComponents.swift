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

struct DashboardReviewMetricPill: View {
  let title: String
  let value: Int
  let tint: Color
  let help: String?

  init(title: String, value: Int, tint: Color, help: String? = nil) {
    self.title = title
    self.value = value
    self.tint = tint
    self.help = help
  }

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      Text(title)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Text(verbatim: String(value))
        .foregroundStyle(tint)
    }
    .scaledFont(.caption.weight(.semibold))
    .lineLimit(1)
    .padding(.horizontal, 8)
    .harnessOpticallyBalancedVerticalPadding(4)
    .background {
      RoundedRectangle(
        cornerRadius: HarnessMonitorTheme.pillCornerRadius,
        style: .continuous
      )
      .fill(tint.opacity(0.14))
    }
    .overlay {
      RoundedRectangle(
        cornerRadius: HarnessMonitorTheme.pillCornerRadius,
        style: .continuous
      )
      .strokeBorder(tint.opacity(0.34), lineWidth: 1)
    }
    .help(expandedHelp)
  }

  /// Expanded summary surfaced via `.help` so abbreviated metric labels
  /// like "Ready" or "Blocked" read in full to screen readers and tooltip
  /// surfaces. Falls back to the explicit `help` override when supplied.
  private var expandedHelp: String {
    if let help, !help.isEmpty {
      return help
    }
    return "\(title): \(value)"
  }
}

struct DashboardReviewStatusPill: View {
  let label: String
  let tint: Color
  var systemImage: String?
  /// Defaults to `true` per the convention documented at the top of this
  /// file. Callers that want the louder weight (the one primary pill per
  /// row's status line) must pass `isQuiet: false` explicitly.
  var isQuiet = true
  var usesSelectedBackgroundContrast = false
  let help: String?

  init(
    label: String,
    tint: Color,
    systemImage: String? = nil,
    isQuiet: Bool = true,
    usesSelectedBackgroundContrast: Bool = false,
    help: String? = nil
  ) {
    self.label = label
    self.tint = tint
    self.systemImage = systemImage
    self.isQuiet = isQuiet
    self.usesSelectedBackgroundContrast = usesSelectedBackgroundContrast
    self.help = help
  }

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      if let systemImage {
        Image(systemName: systemImage)
          .imageScale(.small)
      }
      Text(label)
    }
    .scaledFont(.caption.weight(.semibold))
    .lineLimit(1)
    .padding(.horizontal, 7)
    .harnessOpticallyBalancedVerticalPadding(3)
    .background {
      RoundedRectangle(
        cornerRadius: HarnessMonitorTheme.pillCornerRadius,
        style: .continuous
      )
      .fill(effectiveFillColor)
    }
    .overlay {
      RoundedRectangle(
        cornerRadius: HarnessMonitorTheme.pillCornerRadius,
        style: .continuous
      )
      .strokeBorder(effectiveStrokeColor, lineWidth: 1)
    }
    .foregroundStyle(effectiveForegroundColor)
    .help(help ?? label)
  }

  private var effectiveForegroundColor: Color {
    if usesSelectedBackgroundContrast {
      Color(nsColor: .alternateSelectedControlTextColor)
    } else {
      tint
    }
  }

  private var effectiveFillColor: Color {
    if usesSelectedBackgroundContrast {
      effectiveForegroundColor.opacity(isQuiet ? 0.14 : 0.18)
    } else {
      tint.opacity(isQuiet ? 0.10 : 0.18)
    }
  }

  private var effectiveStrokeColor: Color {
    if usesSelectedBackgroundContrast {
      effectiveForegroundColor.opacity(isQuiet ? 0.32 : 0.42)
    } else {
      tint.opacity(isQuiet ? 0.22 : 0.38)
    }
  }
}

/// Pill that summarises lines-added vs lines-removed for a pull request.
///
/// Two visual modes:
/// - `style == .verbose` (default): the detail-strip `"+N -M"` pill used by
///   `DashboardReviewStatusStrip`.
/// - `style == .compact`: a tighter `"+N -M"` pill the row uses next to the
///   refresh spinner so the change size fits the single-line title row.
struct DashboardReviewChangePill: View {
  enum Style {
    case verbose
    case compact
  }

  let additions: UInt64
  let deletions: UInt64
  let style: Style
  let usesSelectedBackgroundContrast: Bool

  init(
    additions: UInt64,
    deletions: UInt64,
    style: Style = .verbose,
    usesSelectedBackgroundContrast: Bool = false
  ) {
    self.additions = additions
    self.deletions = deletions
    self.style = style
    self.usesSelectedBackgroundContrast = usesSelectedBackgroundContrast
  }

  var body: some View {
    HStack(spacing: style == .compact ? HarnessMonitorTheme.spacingXS : HarnessMonitorTheme.spacingSM) {
      Text(verbatim: "+\(additions)")
        .foregroundStyle(additionsForegroundColor)
        .fixedSize(horizontal: true, vertical: false)
      Text(verbatim: "-\(deletions)")
        .foregroundStyle(deletionsForegroundColor)
        .fixedSize(horizontal: true, vertical: false)
    }
    .scaledFont(.caption.weight(.semibold).monospacedDigit())
    .lineLimit(1)
    .fixedSize(horizontal: true, vertical: false)
    .padding(.horizontal, 7)
    .harnessOpticallyBalancedVerticalPadding(3)
    .background {
      RoundedRectangle(
        cornerRadius: HarnessMonitorTheme.pillCornerRadius,
        style: .continuous
      )
      .fill(changeFillColor)
    }
    .overlay {
      RoundedRectangle(
        cornerRadius: HarnessMonitorTheme.pillCornerRadius,
        style: .continuous
      )
      .strokeBorder(changeStrokeColor, lineWidth: 1)
    }
    .accessibilityLabel(accessibilityLabel)
    .help(accessibilityLabel)
  }

  private var additionsForegroundColor: Color {
    if usesSelectedBackgroundContrast {
      changeForegroundColor
    } else {
      HarnessMonitorTheme.success
    }
  }

  private var deletionsForegroundColor: Color {
    if usesSelectedBackgroundContrast {
      changeForegroundColor
    } else {
      HarnessMonitorTheme.danger
    }
  }

  private var changeForegroundColor: Color {
    if usesSelectedBackgroundContrast {
      Color(nsColor: .alternateSelectedControlTextColor)
    } else {
      HarnessMonitorTheme.secondaryInk
    }
  }

  private var changeFillColor: Color {
    if usesSelectedBackgroundContrast {
      changeForegroundColor.opacity(0.14)
    } else {
      HarnessMonitorTheme.secondaryInk.opacity(0.10)
    }
  }

  private var changeStrokeColor: Color {
    if usesSelectedBackgroundContrast {
      changeForegroundColor.opacity(0.32)
    } else {
      HarnessMonitorTheme.secondaryInk.opacity(0.22)
    }
  }

  private var accessibilityLabel: String {
    DashboardReviewInlineChangeStats.accessibilityLabel(
      additions: additions,
      deletions: deletions
    )
  }
}

struct DashboardReviewInlineChangeStats: View {
  let additions: UInt64
  let deletions: UInt64

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      Text(verbatim: "+\(additions)")
        .foregroundStyle(HarnessMonitorTheme.success)
      Text(verbatim: "-\(deletions)")
        .foregroundStyle(HarnessMonitorTheme.danger)
    }
    .scaledFont(.caption.weight(.semibold).monospacedDigit())
    .lineLimit(1)
    .fixedSize(horizontal: true, vertical: false)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Self.accessibilityLabel(additions: additions, deletions: deletions))
    .help(Self.accessibilityLabel(additions: additions, deletions: deletions))
  }

  static func accessibilityLabel(additions: UInt64, deletions: UInt64) -> String {
    "Line changes: \(additions) \(additions == 1 ? "addition" : "additions"), "
      + "\(deletions) \(deletions == 1 ? "deletion" : "deletions")"
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

  @ViewBuilder
  private var summaryChipsRow: some View {
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

fileprivate enum DashboardReviewAttentionReason: Equatable {
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

    let segments = ([primaryReason.guidanceSentence] + attentionReasons
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
