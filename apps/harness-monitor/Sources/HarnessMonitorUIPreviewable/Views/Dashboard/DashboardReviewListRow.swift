import AppKit
import Foundation
import HarnessMonitorKit
import SwiftUI

/// Single-row presentation of a pull request inside the Reviews route content
/// pane.
///
/// Structure (top to bottom):
/// 1. Title row: optional avatar chip · wrapped title · trailing icon strip
/// 2. Metadata row: optional `#N · age` identity plus repository text on the
///    left, with quieter draft/reviewer/change chrome trailing when present
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
struct DashboardReviewListRow: View, Equatable {
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

  @FocusState private var isFocused: Bool

  let authorChipWidth: CGFloat = 20

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.item == rhs.item
      && lhs.showsRepository == rhs.showsRepository
      && lhs.isSelected == rhs.isSelected
      && lhs.isPinned == rhs.isPinned
      && lhs.isRefreshing == rhs.isRefreshing
      && lhs.actionTitle == rhs.actionTitle
      && lhs.updatedLabel == rhs.updatedLabel
      && lhs.repositoryLabelByName == rhs.repositoryLabelByName
      && lhs.showsAvatars == rhs.showsAvatars
      && lhs.showsLabels == rhs.showsLabels
      && lhs.showsLineCounters == rhs.showsLineCounters
      && lhs.showsPullRequestNumber == rhs.showsPullRequestNumber
      && lhs.showsPullRequestAge == rhs.showsPullRequestAge
      && lhs.wrapsTitle == rhs.wrapsTitle
      && lhs.titleMaximumLines == rhs.titleMaximumLines
      && lhs.hidesSemanticPrefixesInTitle == rhs.hidesSemanticPrefixesInTitle
      && lhs.slaThresholdHours == rhs.slaThresholdHours
  }

  @ScaledMetric(relativeTo: .callout)
  var titleLineHeight: CGFloat = 18
  @ScaledMetric(relativeTo: .caption)
  var captionLineHeight: CGFloat = 14
  @ScaledMetric(relativeTo: .caption)
  var statusPillLineHeight: CGFloat = 20
  @ScaledMetric(relativeTo: .caption)
  var labelStripHeight: CGFloat = 22

  var rowVerticalSpacing: CGFloat { HarnessMonitorTheme.spacingSM }

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
    .contentShape(Rectangle())
    .scaleEffect(isFocused ? 0.995 : 1.0)
    .accessibilityElement(children: .contain)
  }

  // MARK: - Title subviews

  @ViewBuilder var titleBlock: some View {
    HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
      if showsAvatars {
        DashboardReviewListRowAuthorChip(
          login: item.authorLogin,
          avatarURL: item.authorAvatarURL,
          authorAssociation: item.authorAssociation,
          usesSelectedBackgroundContrast: usesSelectedBackgroundContrast
        )
        .frame(height: titleLineHeight, alignment: .center)
      }
      titleLine
        .layoutPriority(1)
      Spacer(minLength: HarnessMonitorTheme.spacingXS)
      DashboardReviewListRowMetadataIconStrip(
        item: item,
        attentionBadges: attentionBadges,
        requiredFailedCheckNames: requiredFailedCheckNames,
        isRefreshing: isRefreshing,
        usesSelectedBackgroundContrast: usesSelectedBackgroundContrast,
        selectedIconDimmedOpacity: selectedIconDimmedOpacity,
        progressAccessibilityLabel: progressAccessibilityLabel,
        statusIndicatorHelp: statusIndicatorHelp
      )
      .frame(height: titleLineHeight, alignment: .center)
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
}

struct DashboardReviewVisibleRequiredFailedCheckNames {
  let visible: ArraySlice<String>
  let overflow: Int
}
