import AppKit
import Foundation
import HarnessMonitorKit
import SwiftUI

/// Single-row presentation of a pull request inside the Reviews route content
/// pane.
///
/// Structure (top to bottom):
/// 1. Title row: status icon · optional avatar chip · wrapped title
/// 2. Metadata row: optional `#N · age` identity plus repository text on the
///    left, with pills trailing only when that identity is visible
/// 3. Optional labels strip: muted chips for `item.labels`
///
/// Pinned rows render a soft `.accent` background tint so they stay visible
/// without needing extra chrome next to the title (the pinned section header
/// already names the section).
///
/// Optional rows now grow the row naturally, while a deterministic
/// `minHeight` floor keeps the existing padding for one-line content and
/// explicit title newlines without adding geometry-driven state. Soft-wrapped
/// titles, pill rows, and label strips therefore take only the height they
/// actually render. Metadata and labels are indented from the title's leading
/// edge so the leading status/author chrome aligns only with the title block.
/// Accessibility uses `children: .contain` (item 31) so the status icon stays
/// an individually-focusable element with its own label (items 32 / 67).
struct DashboardReviewListRow: View {
  let item: ReviewItem
  let showsRepository: Bool
  let isSelected: Bool
  let isPinned: Bool
  let isRefreshing: Bool
  let actionTitle: String?
  let updatedLabel: String
  let repositoryLabelByName: [String: ReviewRepositoryLabel]
  let showsAvatars: Bool
  let showsLabels: Bool
  let showsLineCounters: Bool
  let showsPullRequestNumber: Bool
  let showsPullRequestAge: Bool
  let wrapsTitle: Bool
  let titleMaximumLines: Int
  let hidesSemanticPrefixesInTitle: Bool
  let slaThresholdHours: Int?
  let secondaryText: String?
  let displayTitle: String
  let pullRequestNumberText: String
  let inlineIdentityAndAge: String
  private let displayTitleInlines: [HarnessMarkdownInline]?
  private let attentionBadges: DashboardReviewAttentionBadges
  private let requiredFailedCheckNames: DashboardReviewVisibleRequiredFailedCheckNames?
  private let reviewerSummary: DashboardReviewerSummary?
  private let inlineIdentityAndAgeHelp: String
  let titleAccessibilityText: String

  @Environment(\.fontScale)
  private var fontScale

  @State private var isHovered: Bool = false
  @FocusState private var isFocused: Bool

  let leadingStatusIndicatorWidth: CGFloat = 18
  let authorChipWidth: CGFloat = 16

  @ScaledMetric(relativeTo: .callout)
  var titleLineHeight: CGFloat = 18
  @ScaledMetric(relativeTo: .caption)
  var captionLineHeight: CGFloat = 14
  @ScaledMetric(relativeTo: .caption)
  var statusPillLineHeight: CGFloat = 20
  @ScaledMetric(relativeTo: .caption)
  var labelStripHeight: CGFloat = 22

  var rowVerticalSpacing: CGFloat { HarnessMonitorTheme.spacingSM }

  // Reads `@State private var isHovered`, so it must live in the same file as
  // that state (SwiftLint's private_swiftui_state keeps @State private, and a
  // cross-file extension cannot reach it).
  var rowBackgroundColor: Color {
    if isHovered {
      HarnessMonitorTheme.ink.opacity(0.05)
    } else if isPinned {
      HarnessMonitorTheme.accent.opacity(0.05)
    } else {
      Color.clear
    }
  }

  init(
    item: ReviewItem,
    showsRepository: Bool,
    isSelected: Bool = false,
    isPinned: Bool = false,
    isRefreshing: Bool,
    actionTitle: String?,
    updatedLabel: String,
    repositoryLabelByName: [String: ReviewRepositoryLabel] = [:],
    showsAvatars: Bool = true,
    showsLabels: Bool = true,
    showsLineCounters: Bool = true,
    showsPullRequestNumber: Bool = true,
    showsPullRequestAge: Bool = true,
    wrapsTitle: Bool = true,
    titleMaximumLines: Int = DashboardReviewsPreferences.defaultRowTitleMaximumLines,
    hidesSemanticPrefixesInTitle: Bool = false,
    slaThresholdHours: Int? = nil
  ) {
    self.item = item
    self.showsRepository = showsRepository
    self.isSelected = isSelected
    self.isPinned = isPinned
    self.isRefreshing = isRefreshing
    self.actionTitle = actionTitle
    self.updatedLabel = updatedLabel
    self.repositoryLabelByName = repositoryLabelByName
    self.showsAvatars = showsAvatars
    self.showsLabels = showsLabels
    self.showsLineCounters = showsLineCounters
    self.showsPullRequestNumber = showsPullRequestNumber
    self.showsPullRequestAge = showsPullRequestAge
    self.wrapsTitle = wrapsTitle
    self.titleMaximumLines = titleMaximumLines
    self.hidesSemanticPrefixesInTitle = hidesSemanticPrefixesInTitle
    self.slaThresholdHours = slaThresholdHours
    secondaryText = showsRepository ? item.repository : nil
    let displayTitle = dashboardReviewDisplayedTitle(
      item.title,
      hidesSemanticPrefix: hidesSemanticPrefixesInTitle
    )
    self.displayTitle = displayTitle
    let displayTitleInlines = dashboardReviewInlineTitleInlines(displayTitle)
    self.displayTitleInlines = displayTitleInlines
    titleAccessibilityText =
      displayTitleInlines.map(dashboardReviewInlineTitlePlainText) ?? displayTitle
    let pullRequestNumberText = showsPullRequestNumber ? "#\(item.number)" : ""
    self.pullRequestNumberText = pullRequestNumberText
    let inlineLabels = Self.makeInlineIdentityAndAgeLabels(
      pullRequestNumberText: pullRequestNumberText,
      showsAge: showsPullRequestAge,
      updatedLabel: updatedLabel
    )
    inlineIdentityAndAge = inlineLabels.visible
    inlineIdentityAndAgeHelp = inlineLabels.help
    attentionBadges = Self.dashboardReviewAttentionBadgeKinds(
      for: item, slaThresholdHours: slaThresholdHours)
    requiredFailedCheckNames = Self.makeVisibleRequiredFailedCheckNames(for: item)
    let summary = DashboardReviewerSummary(reviews: item.reviews)
    reviewerSummary = summary.reviewerCount > 0 ? summary : nil
  }

  var body: some View {
    let minimumRowHeight = rowMinimumHeight(
      titleLineCount: estimatedTitleLineCount,
      showsMetadataLine: showsMetadataLine,
      showsLabels: showsLabelsStrip
    )

    VStack(alignment: .leading, spacing: rowVerticalSpacing) {
      titleBlock

      if showsMetadataLine {
        metadataLine
          .padding(.leading, titleContentLeadingInset)
      }

      if showsLabelsStrip {
        DashboardReviewListRowLabelsStrip(
          labels: item.labels,
          labelByName: repositoryLabelByName,
          usesSelectedBackgroundContrast: usesSelectedBackgroundContrast
        )
        .padding(.leading, titleContentLeadingInset)
      }
    }
    .padding(.horizontal, DashboardReviewsVisualMetrics.reviewRowHorizontalPadding)
    .padding(.vertical, DashboardReviewsVisualMetrics.reviewRowVerticalPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(minHeight: minimumRowHeight, alignment: .topLeading)
    .listRowBackground(rowChromeBackground)
    .contentShape(Rectangle())
    .scaleEffect(isFocused ? 0.995 : 1.0)
    .onHover { hovering in
      isHovered = hovering
    }
    .accessibilityElement(children: .contain)
  }

  // MARK: - Title subviews

  @ViewBuilder var titleBlock: some View {
    HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
      leadingStatusIndicator
        .frame(height: titleLineHeight, alignment: .center)
      if showsAvatars {
        DashboardReviewListRowAuthorChip(
          login: item.authorLogin,
          avatarURL: item.authorAvatarURL
        )
        .frame(height: titleLineHeight, alignment: .center)
      }
      titleLine
        .layoutPriority(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder private var titleLine: some View {
    titleLineText
      .lineLimit(effectiveTitleMaximumLines)
      .truncationMode(.tail)
      .fixedSize(horizontal: false, vertical: true)
      .help(item.title)
      .accessibilityLabel(titleAccessibilityLabel)
      .focused($isFocused)
  }

  @ViewBuilder private var titleLineText: some View {
    if let displayTitleInlines {
      Text(
        HarnessMarkdownInlineRenderer.attributedString(
          from: displayTitleInlines,
          style: titleInlineStyle
        )
      )
    } else {
      Text(displayTitle)
        .scaledFont(.callout)
        .foregroundStyle(primaryTextColor)
    }
  }

  @ViewBuilder var leadingStatusIndicator: some View {
    ZStack {
      if isRefreshing {
        ProgressView()
          .controlSize(.small)
          .tint(statusIndicatorColor)
          .accessibilityLabel(progressAccessibilityLabel)
          .transition(.opacity)
      } else {
        Image(systemName: item.statusSystemImage)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(statusIndicatorColor)
          .opacity(item.viewerCanUpdate ? 1 : selectedIconDimmedOpacity)
          .accessibilityLabel(item.statusAccessibilityLabel)
          .transition(.opacity)
      }
    }
    .frame(width: leadingStatusIndicatorWidth, alignment: .center)
    .help(statusIndicatorHelp)
  }

  var progressAccessibilityLabel: String {
    if let actionTitle, !actionTitle.isEmpty {
      "\(actionTitle) pull request"
    } else {
      "Working on pull request"
    }
  }

  var statusIndicatorHelp: String {
    if !item.viewerCanUpdate {
      return "You don't have permission to update this PR"
    }
    return item.statusAccessibilityLabel
  }

  private var titleInlineStyle: HarnessMarkdownInlineRenderStyle {
    HarnessMarkdownInlineRenderStyle(
      font: HarnessMonitorTextSize.scaledFont(.callout, by: fontScale),
      codeFont: HarnessMonitorTextSize.scaledFont(
        .callout.monospaced(),
        by: fontScale
      ),
      colors: usesSelectedBackgroundContrast ? .selectedRow : .default
    )
  }

  // MARK: - Metadata subviews

  @ViewBuilder var metadataLine: some View {
    HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
      if !inlineIdentityAndAge.isEmpty {
        Text(inlineIdentityAndAge)
          .monospacedDigit()
          .scaledFont(.caption)
          .foregroundStyle(secondaryTextColor)
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
          .help(inlineIdentityAndAgeHelp)
          .accessibilityLabel(inlineIdentityAndAgeHelp)
      }

      if let secondary = secondaryText {
        if !inlineIdentityAndAge.isEmpty {
          Text("·")
            .scaledFont(.caption)
            .foregroundStyle(secondaryTextColor)
            .accessibilityHidden(true)
        }
        Text(secondary)
          .scaledFont(.caption)
          .foregroundStyle(secondaryTextColor)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(secondary)
      }

      if shouldRightAlignMetadataPills {
        Spacer(minLength: HarnessMonitorTheme.spacingSM)
      }

      if metadataLineHasPillChrome {
        metadataPillContent
          .layoutPriority(shouldRightAlignMetadataPills ? 0 : 1)
      }
    }
  }

  var metadataLineHasPillChrome: Bool {
    item.isDraft
      || !item.reviews.isEmpty
      || !attentionBadges.isEmpty
      || showsChangePill
  }

  var metadataLineIdealHeight: CGFloat {
    metadataLineHasPillChrome ? statusPillLineHeight : captionLineHeight
  }

  var showsMetadataLine: Bool {
    secondaryText != nil
      || !inlineIdentityAndAge.isEmpty
      || metadataLineHasPillChrome
  }

  @ViewBuilder var metadataPillContent: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      ForEach(attentionBadges.kinds) { kind in
        metadataBadge(kind)
      }

      if item.isDraft {
        DashboardReviewStatusPill(
          label: "Draft",
          tint: HarnessMonitorTheme.secondaryInk,
          systemImage: "pencil.tip.crop.circle",
          isQuiet: true,
          usesSelectedBackgroundContrast: usesSelectedBackgroundContrast
        )
      }

      DashboardReviewListRowReviewerSummary(
        summary: reviewerSummary,
        usesSelectedBackgroundContrast: usesSelectedBackgroundContrast
      )

      if showsChangePill {
        DashboardReviewChangePill(
          additions: item.additions,
          deletions: item.deletions,
          style: .compact,
          usesSelectedBackgroundContrast: usesSelectedBackgroundContrast
        )
      }
    }
  }

  private func metadataBadge(_ kind: DashboardReviewAttentionBadgeKind) -> some View {
    DashboardReviewStatusPill(
      label: kind.label,
      tint: kind.tint,
      systemImage: kind.systemImage,
      isQuiet: true,
      usesSelectedBackgroundContrast: usesSelectedBackgroundContrast,
      help: metadataBadgeHelp(for: kind)
    )
  }

  private func metadataBadgeHelp(for kind: DashboardReviewAttentionBadgeKind) -> String {
    guard kind == .requiredChecks, let requiredFailedCheckNames else { return kind.label }
    let visibleNames = requiredFailedCheckNames.visible.joined(separator: ", ")
    guard !visibleNames.isEmpty else { return kind.label }
    if requiredFailedCheckNames.overflow > 0 {
      return "Required checks: \(visibleNames), +\(requiredFailedCheckNames.overflow) more"
    }
    return "Required checks: \(visibleNames)"
  }
}

struct DashboardReviewVisibleRequiredFailedCheckNames {
  let visible: ArraySlice<String>
  let overflow: Int
}
