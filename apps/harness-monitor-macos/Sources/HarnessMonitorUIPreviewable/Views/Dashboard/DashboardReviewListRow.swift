import HarnessMonitorKit
import SwiftUI

private enum DashboardReviewTitleLineCenterAlignment: AlignmentID {
  static func defaultValue(in context: ViewDimensions) -> CGFloat {
    context[VerticalAlignment.center]
  }
}

extension VerticalAlignment {
  fileprivate static let dashboardReviewTitleLineCenter = VerticalAlignment(
    DashboardReviewTitleLineCenterAlignment.self
  )
}

struct DashboardReviewListRow: View {
  let item: ReviewItem
  let showsRepository: Bool
  let isRefreshing: Bool
  let actionTitle: String?
  let updatedLabel: String

  var body: some View {
    HStack(alignment: .dashboardReviewTitleLineCenter, spacing: HarnessMonitorTheme.spacingSM) {
      leadingStatusIndicator

      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        Text(item.title)
          .scaledFont(.callout.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.ink)
          .lineLimit(1)
          .truncationMode(.tail)
          .alignmentGuide(.dashboardReviewTitleLineCenter) { dimensions in
            dimensions[VerticalAlignment.center]
          }

        Text(secondaryText)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(1)
          .truncationMode(.tail)

        if !attentionBadgeKinds.isEmpty {
          DashboardReviewAttentionBadgeStrip(kinds: attentionBadgeKinds)
        }
      }
      .layoutPriority(1)
    }
    .padding(.horizontal, DashboardReviewsVisualMetrics.reviewRowHorizontalPadding)
    .padding(.vertical, DashboardReviewsVisualMetrics.reviewRowVerticalPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .bottom) {
      Divider()
        .accessibilityHidden(true)
    }
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder private var leadingStatusIndicator: some View {
    ZStack {
      if isRefreshing {
        ProgressView()
          .controlSize(.small)
          .tint(item.statusTint)
          .accessibilityLabel(progressAccessibilityLabel)
          .transition(.opacity)
      } else {
        Image(systemName: item.statusSystemImage)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(item.statusTint)
          .accessibilityHidden(true)
          .transition(.opacity)
      }
    }
    .frame(width: 18, alignment: .center)
  }

  private var progressAccessibilityLabel: String {
    if let actionTitle, !actionTitle.isEmpty {
      "\(actionTitle) pull request"
    } else {
      "Working on pull request"
    }
  }

  private var attentionBadgeKinds: [DashboardReviewAttentionBadgeKind] {
    dashboardReviewAttentionBadgeKinds(for: item)
  }

  private var secondaryText: String {
    let scopedPullRequest =
      showsRepository
      ? "\(item.repository) #\(item.number)"
      : "#\(item.number)"
    return [scopedPullRequest, item.statusLabel, item.reviewStatus.label, updatedLabel]
      .joined(separator: " · ")
  }
}

private struct DashboardReviewAttentionBadgeStrip: View {
  let kinds: [DashboardReviewAttentionBadgeKind]

  var body: some View {
    HarnessMonitorWrapLayout(
      spacing: HarnessMonitorTheme.spacingXS,
      lineSpacing: HarnessMonitorTheme.spacingXS
    ) {
      ForEach(kinds) { kind in
        DashboardReviewStatusPill(
          label: kind.label,
          tint: kind.tint,
          systemImage: kind.systemImage,
          isQuiet: true
        )
      }
    }
  }
}
