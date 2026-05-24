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

/// Single-row presentation of a pull request inside the Reviews route content
/// pane.
///
/// Structure (top to bottom):
/// 1. Title row: status icon · avatar+author chip · title · change pill · refresh spinner
/// 2. Secondary line: `repository · #N` (drops the legacy status/review joiner -
///    that information now lives on the status line and the icon)
/// 3. Status line: status label, reviewer summary, and the relative `updated` label
/// 4. Attention strip: wrapped quiet pills for failing checks, conflicts, etc.
/// 5. Required failed-check names: small `.danger` quiet pills (capped at 3)
/// 6. Labels strip: muted chips for `item.labels`
///
/// All optional rows pad to keep the row's idealHeight stable across content
/// variants (item 34). Accessibility uses `children: .contain` (item 31) so the
/// status icon stays an individually-focusable element with its own label
/// (items 32 / 67).
struct DashboardReviewListRow: View {
  let item: ReviewItem
  let showsRepository: Bool
  let isPinned: Bool
  let isRefreshing: Bool
  let actionTitle: String?
  let updatedLabel: String

  @State private var isHovered: Bool = false
  @FocusState private var isFocused: Bool
  @ScaledMetric(relativeTo: .callout)
  private var titleLineHeight: CGFloat = 18
  @ScaledMetric(relativeTo: .caption)
  private var captionLineHeight: CGFloat = 14
  @ScaledMetric(relativeTo: .caption)
  private var pillStripHeight: CGFloat = 22

  init(
    item: ReviewItem,
    showsRepository: Bool,
    isPinned: Bool = false,
    isRefreshing: Bool,
    actionTitle: String?,
    updatedLabel: String
  ) {
    self.item = item
    self.showsRepository = showsRepository
    self.isPinned = isPinned
    self.isRefreshing = isRefreshing
    self.actionTitle = actionTitle
    self.updatedLabel = updatedLabel
  }

  var body: some View {
    let attentionBadgeKinds = dashboardReviewAttentionBadgeKinds(for: item)
    let requiredFailedCheckNames = visibleRequiredFailedCheckNames()
    let rowIdealHeight = rowIdealHeight(
      hasAttentionStrip: !attentionBadgeKinds.isEmpty,
      hasRequiredFailedChecks: requiredFailedCheckNames != nil
    )

    HStack(alignment: .dashboardReviewTitleLineCenter, spacing: HarnessMonitorTheme.spacingSM) {
      leadingStatusIndicator

      DashboardReviewListRowAuthorChip(
        login: item.authorLogin,
        avatarURL: item.authorAvatarURL
      )

      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        titleLine

        Text(secondaryText)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(1)
          .truncationMode(.tail)
          .help(secondaryText)

        statusLine

        if !attentionBadgeKinds.isEmpty {
          DashboardReviewAttentionBadgeStrip(kinds: attentionBadgeKinds)
        }

        if let names = requiredFailedCheckNames {
          DashboardReviewRequiredFailedCheckStrip(
            visibleNames: names.visible,
            overflow: names.overflow
          )
        }

        if !item.labels.isEmpty {
          DashboardReviewListRowLabelsStrip(labels: item.labels)
        }
      }
      .layoutPriority(1)
    }
    .padding(.horizontal, DashboardReviewsVisualMetrics.reviewRowHorizontalPadding)
    .padding(.vertical, DashboardReviewsVisualMetrics.reviewRowVerticalPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(idealHeight: rowIdealHeight)
    .overlay(alignment: .bottom) {
      Divider()
        .accessibilityHidden(true)
    }
    .background(isHovered ? HarnessMonitorTheme.ink.opacity(0.05) : Color.clear)
    .contentShape(Rectangle())
    .scaleEffect(isFocused ? 0.995 : 1.0)
    .onHover { hovering in
      isHovered = hovering
    }
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder private var titleLine: some View {
    HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
      Text(item.title)
        .scaledFont(.callout.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.ink)
        .lineLimit(1)
        .truncationMode(.tail)
        .help(item.title)
        .accessibilityValue(item.title)
        .alignmentGuide(.dashboardReviewTitleLineCenter) { dimensions in
          dimensions[VerticalAlignment.center]
        }
        .focused($isFocused)

      Spacer(minLength: HarnessMonitorTheme.spacingXS)

      if isPinned {
        Image(systemName: "pin.fill")
          .imageScale(.small)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.dashboardReviewPinnedIndicator(item.pullRequestID)
          )
          .accessibilityLabel("Pinned pull request")
          .help("Pinned pull request")
      }

      if item.additions > 0 || item.deletions > 0 {
        DashboardReviewChangePill(
          additions: item.additions,
          deletions: item.deletions,
          style: .compact
        )
      }
    }
  }

  @ViewBuilder private var statusLine: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      if item.isDraft {
        DashboardReviewStatusPill(
          label: "Draft",
          tint: HarnessMonitorTheme.secondaryInk,
          systemImage: "pencil.tip.crop.circle",
          isQuiet: true
        )
      }

      DashboardReviewListRowReviewerSummary(item: item)

      if !updatedLabel.isEmpty {
        Text(updatedLabel)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(1)
      }
    }
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
          .opacity(item.viewerCanUpdate ? 1 : 0.4)
          .accessibilityLabel(item.statusAccessibilityLabel)
          .transition(.opacity)
      }
    }
    .frame(width: 18, alignment: .center)
    .help(statusIndicatorHelp)
  }

  private var progressAccessibilityLabel: String {
    if let actionTitle, !actionTitle.isEmpty {
      "\(actionTitle) pull request"
    } else {
      "Working on pull request"
    }
  }

  private var statusIndicatorHelp: String {
    if !item.viewerCanUpdate {
      return "You don't have permission to update this PR"
    }
    return item.statusAccessibilityLabel
  }

  /// Drops the legacy `statusLabel · reviewStatus.label` joiner (items 21 + 35)
  /// — those signals now live on the status icon and the inline status line.
  /// The remaining line is just identity: `repository · #N` (or `#N` alone).
  var secondaryText: String {
    showsRepository
      ? "\(item.repository) · #\(item.number)"
      : "#\(item.number)"
  }

  private func visibleRequiredFailedCheckNames() -> (visible: [String], overflow: Int)? {
    guard item.hasRequiredFailedChecks else { return nil }
    let names = item.requiredFailedCheckNames
    guard !names.isEmpty else { return nil }
    let cap = 3
    if names.count <= cap {
      return (visible: names, overflow: 0)
    }
    return (visible: Array(names.prefix(cap)), overflow: names.count - cap)
  }

  fileprivate func rowIdealHeight(
    hasAttentionStrip: Bool,
    hasRequiredFailedChecks: Bool
  ) -> CGFloat {
    DashboardReviewListRowHeight.idealHeight(
      DashboardReviewListRowHeight.Layout(
        titleLineHeight: titleLineHeight,
        captionLineHeight: captionLineHeight,
        pillStripHeight: pillStripHeight,
        hasAttentionStrip: hasAttentionStrip,
        hasRequiredFailedChecks: hasRequiredFailedChecks,
        hasLabels: !item.labels.isEmpty,
        verticalPadding: DashboardReviewsVisualMetrics.reviewRowVerticalPadding,
        lineSpacing: HarnessMonitorTheme.spacingXS
      )
    )
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

private struct DashboardReviewRequiredFailedCheckStrip: View {
  let visibleNames: [String]
  let overflow: Int

  var body: some View {
    HarnessMonitorWrapLayout(
      spacing: HarnessMonitorTheme.spacingXS,
      lineSpacing: HarnessMonitorTheme.spacingXS
    ) {
      ForEach(visibleNames, id: \.self) { name in
        DashboardReviewStatusPill(
          label: name,
          tint: HarnessMonitorTheme.danger,
          systemImage: "xmark.circle",
          isQuiet: true
        )
      }
      if overflow > 0 {
        DashboardReviewStatusPill(
          label: "+\(overflow) more",
          tint: HarnessMonitorTheme.danger,
          isQuiet: true
        )
      }
    }
  }
}
