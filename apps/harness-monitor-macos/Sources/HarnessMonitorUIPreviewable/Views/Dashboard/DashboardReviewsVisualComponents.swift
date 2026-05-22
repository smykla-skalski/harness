import HarnessMonitorKit
import SwiftUI

enum DashboardReviewsVisualMetrics {
  static let pillCornerRadius: CGFloat = 7
  static let reviewRowHorizontalPadding: CGFloat = 4
  static let reviewRowVerticalPadding: CGFloat = 10
  static let sectionMaxWidth: CGFloat = 940
  static let checksMaxWidth: CGFloat = 680
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
            systemImage: "archivebox"
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
        cornerRadius: DashboardReviewsVisualMetrics.pillCornerRadius,
        style: .continuous
      )
      .fill(tint.opacity(0.14))
    }
    .overlay {
      RoundedRectangle(
        cornerRadius: DashboardReviewsVisualMetrics.pillCornerRadius,
        style: .continuous
      )
      .strokeBorder(tint.opacity(0.34), lineWidth: 1)
    }
  }
}

struct DashboardReviewStatusPill: View {
  let label: String
  let tint: Color
  var systemImage: String?
  var isQuiet = false

  init(
    label: String,
    tint: Color,
    systemImage: String? = nil,
    isQuiet: Bool = false
  ) {
    self.label = label
    self.tint = tint
    self.systemImage = systemImage
    self.isQuiet = isQuiet
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
        cornerRadius: DashboardReviewsVisualMetrics.pillCornerRadius,
        style: .continuous
      )
      .fill(tint.opacity(isQuiet ? 0.10 : 0.18))
    }
    .overlay {
      RoundedRectangle(
        cornerRadius: DashboardReviewsVisualMetrics.pillCornerRadius,
        style: .continuous
      )
      .strokeBorder(tint.opacity(isQuiet ? 0.22 : 0.38), lineWidth: 1)
    }
    .foregroundStyle(tint)
  }
}

private struct DashboardReviewChangePill: View {
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
    .padding(.horizontal, 7)
    .padding(.vertical, 3)
    .background {
      RoundedRectangle(
        cornerRadius: DashboardReviewsVisualMetrics.pillCornerRadius,
        style: .continuous
      )
      .fill(HarnessMonitorTheme.secondaryInk.opacity(0.10))
    }
    .overlay {
      RoundedRectangle(
        cornerRadius: DashboardReviewsVisualMetrics.pillCornerRadius,
        style: .continuous
      )
      .strokeBorder(HarnessMonitorTheme.secondaryInk.opacity(0.22), lineWidth: 1)
    }
    .accessibilityLabel(accessibilityLabel)
  }

  private var accessibilityLabel: String {
    "\(additions) \(additions == 1 ? "addition" : "additions"), \(deletions) "
      + (deletions == 1 ? "deletion" : "deletions")
  }
}

struct DashboardReviewStatusStrip: View {
  let item: ReviewItem

  var body: some View {
    HarnessMonitorWrapLayout(
      spacing: HarnessMonitorTheme.spacingSM,
      lineSpacing: HarnessMonitorTheme.spacingSM
    ) {
      DashboardReviewStatusPill(label: item.statusLabel, tint: item.statusTint)
      DashboardReviewStatusPill(
        label: item.reviewStatus.label,
        tint: item.reviewStatus.tint,
        isQuiet: true
      )
      DashboardReviewChangePill(additions: item.additions, deletions: item.deletions)
      if item.policyBlocked {
        DashboardReviewStatusPill(
          label: "Policy wait",
          tint: HarnessMonitorTheme.caution,
          systemImage: "hourglass",
          isQuiet: true
        )
      }
    }
  }
}
