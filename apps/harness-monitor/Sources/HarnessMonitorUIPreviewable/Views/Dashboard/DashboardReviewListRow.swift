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
/// 1. Title row: status icon · avatar+author chip · title (up to 2 lines) · change pill
/// 2. Secondary line (ungrouped only): `repository · #N`. Collapses entirely
///    when the list is grouped by repository — `#N` rides inline on the status
///    line instead so the row never burns a caption line on the PR number alone.
/// 3. Status line: draft pill, reviewer summary, and `#N · updated` (or just
///    the relative `updated` label in ungrouped mode)
/// 4. Attention strip: wrapped quiet pills for failing checks, conflicts, etc.
/// 5. Required failed-check names: small `.danger` quiet pills (capped at 3)
/// 6. Labels strip: muted chips for `item.labels`
///
/// Pinned rows render an `.accent` left stripe and a soft accent background
/// tint so they stay visible without needing a duplicate pin glyph next to
/// the title (the pinned section header already names the section).
///
/// All optional rows pad to keep the row's idealHeight stable across content
/// variants (item 34). The title always reserves two lines of vertical space
/// so wrapping does not shift sibling rows. Accessibility uses
/// `children: .contain` (item 31) so the status icon stays an individually-
/// focusable element with its own label (items 32 / 67).
struct DashboardReviewListRow: View {
  let item: ReviewItem
  let showsRepository: Bool
  let isPinned: Bool
  let isRefreshing: Bool
  let actionTitle: String?
  let updatedLabel: String
  let repositoryLabels: [ReviewRepositoryLabel]

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
    updatedLabel: String,
    repositoryLabels: [ReviewRepositoryLabel] = []
  ) {
    self.item = item
    self.showsRepository = showsRepository
    self.isPinned = isPinned
    self.isRefreshing = isRefreshing
    self.actionTitle = actionTitle
    self.updatedLabel = updatedLabel
    self.repositoryLabels = repositoryLabels
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

        if let secondary = secondaryText {
          Text(secondary)
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(secondary)
        }

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
          DashboardReviewListRowLabelsStrip(
            labels: item.labels,
            repositoryLabels: repositoryLabels
          )
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
    .overlay(alignment: .leading) {
      if isPinned {
        Rectangle()
          .fill(HarnessMonitorTheme.accent)
          .frame(width: 3)
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.dashboardReviewPinnedIndicator(item.pullRequestID)
          )
          .accessibilityLabel("Pinned pull request")
          .help("Pinned pull request")
      }
    }
    .background(rowBackground)
    .contentShape(Rectangle())
    .scaleEffect(isFocused ? 0.995 : 1.0)
    .onHover { hovering in
      isHovered = hovering
    }
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder private var rowBackground: some View {
    if isHovered {
      HarnessMonitorTheme.ink.opacity(0.05)
    } else if isPinned {
      HarnessMonitorTheme.accent.opacity(0.05)
    } else {
      Color.clear
    }
  }

  @ViewBuilder private var titleLine: some View {
    HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
      Text(item.title)
        .scaledFont(.callout.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.ink)
        .lineLimit(2)
        .truncationMode(.tail)
        .help(item.title)
        .accessibilityValue(item.title)
        .alignmentGuide(.dashboardReviewTitleLineCenter) { dimensions in
          dimensions[VerticalAlignment.center]
        }
        .focused($isFocused)

      Spacer(minLength: HarnessMonitorTheme.spacingXS)

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

      if !inlineIdentityAndAge.isEmpty {
        Text(inlineIdentityAndAge)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(1)
          .help(inlineIdentityAndAgeHelp)
      }
    }
  }

  /// `#N` identity plus the relative-age label, joined on the status line.
  /// When the row already shows `repository · #N` on its secondary line
  /// (ungrouped mode), only the age renders here to avoid repeating the
  /// PR number twice. Exposed for unit tests that pin the row contract.
  var inlineIdentityAndAge: String {
    inlineIdentityAndAgeParts(ageFormat: { $0 }).joined(separator: " · ")
  }

  /// Verbose form of `inlineIdentityAndAge` used as the `.help` tooltip so
  /// hover surfaces the absolute meaning of the relative age (e.g.
  /// `Updated 3h ago` rather than just `3h ago`).
  private var inlineIdentityAndAgeHelp: String {
    inlineIdentityAndAgeParts(ageFormat: { "Updated \($0)" }).joined(separator: " · ")
  }

  /// Shared builder for the `#N` + age parts used by both
  /// `inlineIdentityAndAge` and `inlineIdentityAndAgeHelp`. The age component
  /// is funneled through the caller-provided `ageFormat` so the visible
  /// caption stays terse while the tooltip can expand it.
  private func inlineIdentityAndAgeParts(
    ageFormat: (String) -> String
  ) -> [String] {
    var parts: [String] = []
    if !showsRepository {
      parts.append("#\(item.number)")
    }
    if !updatedLabel.isEmpty {
      parts.append(ageFormat(updatedLabel))
    }
    return parts
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

  /// Identity line, rendered between the title and the status line.
  /// Only emitted when the row needs to disambiguate repository origin
  /// (ungrouped mode); when the list is grouped by repository, the PR number
  /// rides inline on the status line and this slot collapses entirely so the
  /// row doesn't waste a caption line on `#N` alone.
  var secondaryText: String? {
    showsRepository ? "\(item.repository) · #\(item.number)" : nil
  }

  private func visibleRequiredFailedCheckNames() -> (visible: ArraySlice<String>, overflow: Int)? {
    guard item.hasRequiredFailedChecks else { return nil }
    let names = item.requiredFailedCheckNames
    guard !names.isEmpty else { return nil }
    let cap = 3
    return (visible: names.prefix(cap), overflow: max(0, names.count - cap))
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
        hasWrappedTitle: DashboardReviewListRowHeight.titleLikelyWraps(item.title),
        hasSecondaryLine: secondaryText != nil,
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
  let visibleNames: ArraySlice<String>
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
