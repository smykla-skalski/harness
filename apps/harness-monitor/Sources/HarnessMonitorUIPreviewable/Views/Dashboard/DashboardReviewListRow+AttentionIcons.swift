import AppKit
import HarnessMonitorKit
import SwiftUI

struct DashboardReviewListRowMetadataIconStrip: View {
  let item: ReviewItem
  let attentionBadges: DashboardReviewAttentionBadges
  let requiredFailedCheckNames: DashboardReviewVisibleRequiredFailedCheckNames?
  let isRefreshing: Bool
  let usesSelectedBackgroundContrast: Bool
  let isRowHovered: Bool
  let selectedIconDimmedOpacity: Double
  let progressAccessibilityLabel: String
  let statusIndicatorHelp: String

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      if item.viewerIsRequestedReviewer {
        DashboardReviewListRowMetadataIcon(
          label: "Needs me",
          systemImage: "person.crop.circle.badge.checkmark",
          tint: HarnessMonitorTheme.accent,
          mutedUntilHovered: true,
          usesSelectedBackgroundContrast: usesSelectedBackgroundContrast,
          isRowHovered: isRowHovered,
          help: "You are a requested reviewer"
        )
      }

      ForEach(attentionBadges.kinds) { kind in
        attentionIcon(kind)
      }

      DashboardReviewListRowMetadataStatusIcon(
        item: item,
        isRefreshing: isRefreshing,
        usesSelectedBackgroundContrast: usesSelectedBackgroundContrast,
        selectedIconDimmedOpacity: selectedIconDimmedOpacity,
        progressAccessibilityLabel: progressAccessibilityLabel,
        statusIndicatorHelp: statusIndicatorHelp
      )
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  @ViewBuilder
  private func attentionIcon(_ kind: DashboardReviewAttentionBadgeKind) -> some View {
    if let systemImage = kind.systemImage {
      DashboardReviewListRowMetadataIcon(
        label: kind.label,
        systemImage: systemImage,
        tint: kind.tint,
        mutedUntilHovered: true,
        usesSelectedBackgroundContrast: usesSelectedBackgroundContrast,
        isRowHovered: isRowHovered,
        help: metadataHelp(for: kind)
      )
    }
  }

  private func metadataHelp(for kind: DashboardReviewAttentionBadgeKind) -> String {
    guard kind == .requiredChecks, let requiredFailedCheckNames else { return kind.label }
    let visibleNames = requiredFailedCheckNames.visible.joined(separator: ", ")
    guard !visibleNames.isEmpty else { return kind.label }
    if requiredFailedCheckNames.overflow > 0 {
      return "Required checks: \(visibleNames), +\(requiredFailedCheckNames.overflow) more"
    }
    return "Required checks: \(visibleNames)"
  }
}

private struct DashboardReviewListRowMetadataIcon: View {
  let label: String
  let systemImage: String
  let tint: Color
  let mutedUntilHovered: Bool
  let usesSelectedBackgroundContrast: Bool
  let isRowHovered: Bool
  let help: String

  var body: some View {
    Image(systemName: systemImage)
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(iconForegroundColor)
      .accessibilityLabel(label)
      .accessibilityHint(accessibilityHint)
      .help(help)
      .animation(.easeInOut(duration: 0.16), value: isRowHovered)
  }

  private var iconForegroundColor: Color {
    let selectedForeground = Color(nsColor: .alternateSelectedControlTextColor)
    if usesSelectedBackgroundContrast {
      return selectedForeground.opacity(mutedUntilHovered ? 0.82 : 0.96)
    }
    if mutedUntilHovered && !isRowHovered {
      return HarnessMonitorTheme.secondaryInk.opacity(0.44)
    }
    return tint
  }

  private var accessibilityHint: String {
    help == label ? "" : help
  }
}

private struct DashboardReviewListRowMetadataStatusIcon: View {
  let item: ReviewItem
  let isRefreshing: Bool
  let usesSelectedBackgroundContrast: Bool
  let selectedIconDimmedOpacity: Double
  let progressAccessibilityLabel: String
  let statusIndicatorHelp: String

  var body: some View {
    ZStack {
      if isRefreshing {
        ProgressView()
          .controlSize(.small)
          .tint(statusIndicatorColor)
          .accessibilityLabel(progressAccessibilityLabel)
      } else {
        Image(systemName: item.statusSystemImage)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(statusIndicatorColor)
          .opacity(item.viewerCanUpdate ? 1 : selectedIconDimmedOpacity)
          .accessibilityLabel(item.statusAccessibilityLabel)
      }
    }
    .frame(width: 14, alignment: .center)
    .help(statusIndicatorHelp)
  }

  private var statusIndicatorColor: Color {
    if usesSelectedBackgroundContrast {
      Color(nsColor: .alternateSelectedControlTextColor)
    } else {
      item.statusTint
    }
  }
}
