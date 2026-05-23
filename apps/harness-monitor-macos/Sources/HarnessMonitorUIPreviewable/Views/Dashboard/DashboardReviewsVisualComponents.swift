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
  static let reviewRowVerticalPadding: CGFloat = 10
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
    .padding(.vertical, 4)
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
  let help: String?

  init(
    label: String,
    tint: Color,
    systemImage: String? = nil,
    isQuiet: Bool = true,
    help: String? = nil
  ) {
    self.label = label
    self.tint = tint
    self.systemImage = systemImage
    self.isQuiet = isQuiet
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
    .padding(.vertical, 3)
    .background {
      RoundedRectangle(
        cornerRadius: HarnessMonitorTheme.pillCornerRadius,
        style: .continuous
      )
      .fill(tint.opacity(isQuiet ? 0.10 : 0.18))
    }
    .overlay {
      RoundedRectangle(
        cornerRadius: HarnessMonitorTheme.pillCornerRadius,
        style: .continuous
      )
      .strokeBorder(tint.opacity(isQuiet ? 0.22 : 0.38), lineWidth: 1)
    }
    .foregroundStyle(tint)
    .help(help ?? label)
  }
}

/// Pill that summarises lines-added vs lines-removed for a pull request.
///
/// Two visual modes:
/// - `style == .verbose` (default): the detail-strip `"Files ↑N ↓M"` pill used
///   by `DashboardReviewStatusStrip`.
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

  init(additions: UInt64, deletions: UInt64, style: Style = .verbose) {
    self.additions = additions
    self.deletions = deletions
    self.style = style
  }

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      if style == .verbose {
        Text("Files")
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      HStack(spacing: style == .compact ? HarnessMonitorTheme.spacingXS : 0) {
        if style == .verbose {
          Image(systemName: "arrow.up")
            .imageScale(.small)
            .foregroundStyle(HarnessMonitorTheme.success)
            .accessibilityHidden(true)
        }
        Text(verbatim: style == .compact ? "+\(additions)" : "\(additions)")
          .foregroundStyle(HarnessMonitorTheme.success)
          .fixedSize(horizontal: true, vertical: false)
      }
      HStack(spacing: style == .compact ? HarnessMonitorTheme.spacingXS : 0) {
        if style == .verbose {
          Image(systemName: "arrow.down")
            .imageScale(.small)
            .foregroundStyle(HarnessMonitorTheme.danger)
            .accessibilityHidden(true)
        }
        Text(verbatim: style == .compact ? "-\(deletions)" : "\(deletions)")
          .foregroundStyle(HarnessMonitorTheme.danger)
          .fixedSize(horizontal: true, vertical: false)
      }
    }
    .scaledFont(.caption.weight(.semibold).monospacedDigit())
    .lineLimit(1)
    .fixedSize(horizontal: true, vertical: false)
    .padding(.horizontal, 7)
    .padding(.vertical, 3)
    .background {
      RoundedRectangle(
        cornerRadius: HarnessMonitorTheme.pillCornerRadius,
        style: .continuous
      )
      .fill(HarnessMonitorTheme.secondaryInk.opacity(0.10))
    }
    .overlay {
      RoundedRectangle(
        cornerRadius: HarnessMonitorTheme.pillCornerRadius,
        style: .continuous
      )
      .strokeBorder(HarnessMonitorTheme.secondaryInk.opacity(0.22), lineWidth: 1)
    }
    .accessibilityLabel(accessibilityLabel)
    .help(accessibilityLabel)
  }

  private var accessibilityLabel: String {
    "Files: \(additions) \(additions == 1 ? "addition" : "additions"), "
      + "\(deletions) \(deletions == 1 ? "deletion" : "deletions")"
  }
}

struct DashboardReviewStatusStrip: View {
  let item: ReviewItem

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
        DashboardReviewStatusPill(
          label: item.statusLabel,
          tint: item.statusTint,
          systemImage: item.requiresAttention ? nil : item.statusSystemImage,
          isQuiet: false
        )
        Text(item.statusSentence)
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
        DashboardReviewChangePill(additions: item.additions, deletions: item.deletions)
        if item.policyBlocked {
          DashboardReviewStatusPill(
            label: "Policy blocked",
            tint: HarnessMonitorTheme.caution,
            systemImage: "hourglass",
            isQuiet: true
          )
        }
      }
    }
  }
}

struct DashboardReviewAttentionSummary: View {
  let item: ReviewItem

  var body: some View {
    HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(HarnessMonitorTheme.caution)
        .imageScale(.medium)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        Text("Needs attention before merge")
          .scaledFont(.caption.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.ink)
        Text(item.attentionSentence)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(
      HarnessMonitorTheme.caution.opacity(0.10),
      in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(HarnessMonitorTheme.caution.opacity(0.24), lineWidth: 1)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Review needs attention")
    .accessibilityValue(item.attentionSentence)
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
  var statusSentence: String {
    var parts: [String] = []
    parts.append(reviewStatus.statusSentenceFragment)
    parts.append(checkStatus.statusSentenceFragment)
    if policyBlocked {
      parts.append("review policy is blocking merge")
    }
    if mergeable == .conflicting {
      parts.append("merge conflicts need resolution")
    }
    return parts.joined(separator: ", ") + "."
  }

  var attentionSentence: String {
    var reasons: [String] = []
    if hasRequiredFailedChecks {
      reasons.append(
        "Required checks are failing: \(requiredFailedCheckNames.joined(separator: ", "))."
      )
    } else if checkStatus == .failure {
      reasons.append("Checks are failing.")
    }
    if policyBlocked {
      reasons.append("Review policy is blocking merge even though review state can be approved.")
    }
    if reviewStatus == .changesRequested {
      reasons.append("A reviewer requested changes.")
    }
    if mergeable == .conflicting {
      reasons.append("Merge conflicts must be resolved.")
    }
    return reasons.isEmpty ? "No attention reason is reported." : reasons.joined(separator: " ")
  }
}
