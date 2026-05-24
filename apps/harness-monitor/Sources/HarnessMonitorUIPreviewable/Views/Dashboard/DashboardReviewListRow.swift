import Foundation
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
/// actually render. Accessibility uses `children: .contain` (item 31) so the
/// status icon stays an individually-focusable element with its own label
/// (items 32 / 67).
struct DashboardReviewListRow: View {
  let item: ReviewItem
  let showsRepository: Bool
  let isPinned: Bool
  let isRefreshing: Bool
  let actionTitle: String?
  let updatedLabel: String
  let repositoryLabels: [ReviewRepositoryLabel]
  let showsAvatars: Bool
  let showsLabels: Bool
  let showsLineCounters: Bool
  let showsPullRequestNumber: Bool
  let showsPullRequestAge: Bool
  let wrapsTitle: Bool
  let titleMaximumLines: Int
  let hidesSemanticPrefixesInTitle: Bool
  let secondaryText: String?
  let pullRequestNumberText: String
  let inlineIdentityAndAge: String
  private let attentionBadges: DashboardReviewAttentionBadges
  private let requiredFailedCheckNames: DashboardReviewVisibleRequiredFailedCheckNames?
  private let inlineIdentityAndAgeHelp: String

  @State private var isHovered: Bool = false
  @FocusState private var isFocused: Bool
  @ScaledMetric(relativeTo: .callout)
  private var titleLineHeight: CGFloat = 18
  @ScaledMetric(relativeTo: .caption)
  private var captionLineHeight: CGFloat = 14
  @ScaledMetric(relativeTo: .caption)
  private var statusPillLineHeight: CGFloat = 20
  @ScaledMetric(relativeTo: .caption)
  private var labelStripHeight: CGFloat = 22

  private var rowVerticalSpacing: CGFloat { HarnessMonitorTheme.spacingSM }

  init(
    item: ReviewItem,
    showsRepository: Bool,
    isPinned: Bool = false,
    isRefreshing: Bool,
    actionTitle: String?,
    updatedLabel: String,
    repositoryLabels: [ReviewRepositoryLabel] = [],
    showsAvatars: Bool = true,
    showsLabels: Bool = true,
    showsLineCounters: Bool = true,
    showsPullRequestNumber: Bool = true,
    showsPullRequestAge: Bool = true,
    wrapsTitle: Bool = true,
    titleMaximumLines: Int = DashboardReviewsPreferences.defaultRowTitleMaximumLines,
    hidesSemanticPrefixesInTitle: Bool = false
  ) {
    self.item = item
    self.showsRepository = showsRepository
    self.isPinned = isPinned
    self.isRefreshing = isRefreshing
    self.actionTitle = actionTitle
    self.updatedLabel = updatedLabel
    self.repositoryLabels = repositoryLabels
    self.showsAvatars = showsAvatars
    self.showsLabels = showsLabels
    self.showsLineCounters = showsLineCounters
    self.showsPullRequestNumber = showsPullRequestNumber
    self.showsPullRequestAge = showsPullRequestAge
    self.wrapsTitle = wrapsTitle
    self.titleMaximumLines = titleMaximumLines
    self.hidesSemanticPrefixesInTitle = hidesSemanticPrefixesInTitle
    secondaryText = showsRepository ? item.repository : nil
    let pullRequestNumberText = showsPullRequestNumber ? "#\(item.number)" : ""
    self.pullRequestNumberText = pullRequestNumberText
    let inlineLabels = Self.makeInlineIdentityAndAgeLabels(
      pullRequestNumberText: pullRequestNumberText,
      showsAge: showsPullRequestAge,
      updatedLabel: updatedLabel
    )
    inlineIdentityAndAge = inlineLabels.visible
    inlineIdentityAndAgeHelp = inlineLabels.help
    attentionBadges = Self.dashboardReviewAttentionBadgeKinds(for: item)
    requiredFailedCheckNames = Self.makeVisibleRequiredFailedCheckNames(for: item)
  }

  var body: some View {
    let minimumRowHeight = rowMinimumHeight(
      titleLineCount: estimatedTitleLineCount,
      showsMetadataLine: showsMetadataLine,
      showsLabels: showsLabelsStrip
    )

    HStack(alignment: .dashboardReviewTitleLineCenter, spacing: HarnessMonitorTheme.spacingSM) {
      leadingStatusIndicator

      if showsAvatars {
        DashboardReviewListRowAuthorChip(
          login: item.authorLogin,
          avatarURL: item.authorAvatarURL
        )
      }

      VStack(alignment: .leading, spacing: rowVerticalSpacing) {
        titleLine

        if showsMetadataLine {
          metadataLine
        }

        if showsLabelsStrip {
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
    .frame(minHeight: minimumRowHeight, alignment: .topLeading)
    .listRowBackground(rowChromeBackground)
    .contentShape(Rectangle())
    .scaleEffect(isFocused ? 0.995 : 1.0)
    .onHover { hovering in
      isHovered = hovering
    }
    .accessibilityElement(children: .contain)
  }

  private var rowBackgroundColor: Color {
    if isHovered {
      HarnessMonitorTheme.ink.opacity(0.05)
    } else if isPinned {
      HarnessMonitorTheme.accent.opacity(0.05)
    } else {
      Color.clear
    }
  }

  private var rowChromeBackground: some View {
    ZStack {
      rowBackgroundColor
      VStack(spacing: 0) {
        Spacer(minLength: 0)
        Rectangle()
          .fill(Color(nsColor: .separatorColor))
          .frame(height: 1)
          .accessibilityHidden(true)
      }
    }
  }

  @ViewBuilder private var titleLine: some View {
    let titleFirstLineCenterOffset = titleLineHeight / 2
    HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
      Text(displayTitle)
        .scaledFont(.callout.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.ink)
        .lineLimit(effectiveTitleMaximumLines)
        .truncationMode(.tail)
        .fixedSize(horizontal: false, vertical: true)
        .help(item.title)
        .accessibilityLabel(titleAccessibilityLabel)
        .alignmentGuide(.dashboardReviewTitleLineCenter) { dimensions in
          dimensions[VerticalAlignment.firstTextBaseline] - titleFirstLineCenterOffset
        }
        .layoutPriority(1)
        .focused($isFocused)
    }
  }

  @ViewBuilder private var metadataLine: some View {
    HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
      if !inlineIdentityAndAge.isEmpty {
        Text(inlineIdentityAndAge)
          .monospacedDigit()
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
          .help(inlineIdentityAndAgeHelp)
          .accessibilityLabel(inlineIdentityAndAgeHelp)
      }

      if let secondary = secondaryText {
        if !inlineIdentityAndAge.isEmpty {
          Text("·")
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .accessibilityHidden(true)
        }
        Text(secondary)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
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

  @ViewBuilder private var metadataPillContent: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      ForEach(attentionBadges.kinds) { kind in
        metadataBadge(kind)
      }

      if item.isDraft {
        DashboardReviewStatusPill(
          label: "Draft",
          tint: HarnessMonitorTheme.secondaryInk,
          systemImage: "pencil.tip.crop.circle",
          isQuiet: true
        )
      }

      DashboardReviewListRowReviewerSummary(item: item)

      if showsChangePill {
        DashboardReviewChangePill(
          additions: item.additions,
          deletions: item.deletions,
          style: .compact
        )
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

  /// Prepares the visible `#N · age` caption plus its verbose help label.
  /// The row body reads these labels multiple times, so keeping them as stored
  /// values avoids per-render array and join work across long review lists.
  private static func makeInlineIdentityAndAgeLabels(
    pullRequestNumberText: String,
    showsAge: Bool,
    updatedLabel: String
  ) -> (visible: String, help: String) {
    var visibleParts: [String] = []
    var helpParts: [String] = []

    if !pullRequestNumberText.isEmpty {
      visibleParts.append(pullRequestNumberText)
      helpParts.append("Pull request \(pullRequestNumberText)")
    }

    if showsAge, !updatedLabel.isEmpty {
      visibleParts.append(updatedLabel)
      helpParts.append("Updated \(updatedLabel)")
    }

    return (
      visible: visibleParts.joined(separator: " · "),
      help: helpParts.joined(separator: " · ")
    )
  }

  private static func makeVisibleRequiredFailedCheckNames(
    for item: ReviewItem
  ) -> DashboardReviewVisibleRequiredFailedCheckNames? {
    guard item.hasRequiredFailedChecks else { return nil }
    let names = item.requiredFailedCheckNames
    guard !names.isEmpty else { return nil }
    let cap = 3
    return DashboardReviewVisibleRequiredFailedCheckNames(
      visible: names.prefix(cap),
      overflow: max(0, names.count - cap)
    )
  }

  private static func dashboardReviewAttentionBadgeKinds(
    for item: ReviewItem
  ) -> DashboardReviewAttentionBadges {
    DashboardReviewAttentionBadges(item: item)
  }

  fileprivate func rowMinimumHeight(
    titleLineCount: Int,
    showsMetadataLine: Bool,
    showsLabels: Bool
  ) -> CGFloat {
    DashboardReviewListRowHeight.minimumHeight(
      DashboardReviewListRowHeight.Layout(
        titleLineHeight: titleLineHeight,
        captionLineHeight: captionLineHeight,
        pillStripHeight: statusPillLineHeight,
        hasWrappedTitle: titleLineCount > 1,
        titleLineCount: titleLineCount,
        hasSecondaryLine: false,
        hasAttentionStrip: false,
        hasRequiredFailedChecks: false,
        hasLabels: showsLabels,
        verticalPadding: DashboardReviewsVisualMetrics.reviewRowVerticalPadding,
        lineSpacing: rowVerticalSpacing,
        statusLineHeight: showsMetadataLine ? metadataLineIdealHeight : 0,
        labelsStripHeight: labelStripHeight
      )
    )
  }

  private var metadataLineIdealHeight: CGFloat {
    metadataLineHasPillChrome ? statusPillLineHeight : captionLineHeight
  }

  private var metadataLineHasPillChrome: Bool {
    item.isDraft
      || !item.reviews.isEmpty
      || !attentionBadges.isEmpty
      || showsChangePill
  }

  private var shouldRightAlignMetadataPills: Bool {
    !inlineIdentityAndAge.isEmpty
  }

  private var showsMetadataLine: Bool {
    secondaryText != nil
      || !inlineIdentityAndAge.isEmpty
      || metadataLineHasPillChrome
  }

  private var showsLabelsStrip: Bool {
    showsLabels && !item.labels.isEmpty
  }

  private var showsChangePill: Bool {
    showsLineCounters && (item.additions > 0 || item.deletions > 0)
  }

  private var effectiveTitleMaximumLines: Int {
    if !wrapsTitle {
      return 1
    }
    return min(
      max(titleMaximumLines, DashboardReviewsPreferences.minimumRowTitleMaximumLines),
      DashboardReviewsPreferences.maximumRowTitleMaximumLines
    )
  }

  private var estimatedTitleLineCount: Int {
    DashboardReviewListRowHeight.estimatedTitleLineCount(
      displayTitle,
      maximumLines: effectiveTitleMaximumLines
    )
  }

  private var displayTitle: String {
    dashboardReviewDisplayedTitle(
      item.title,
      hidesSemanticPrefix: hidesSemanticPrefixesInTitle
    )
  }

  private var titleAccessibilityLabel: String {
    let trimmedAuthorLogin = item.authorLogin.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !showsAvatars, !trimmedAuthorLogin.isEmpty else { return displayTitle }
    return "\(displayTitle), by @\(trimmedAuthorLogin)"
  }

  private func metadataBadge(_ kind: DashboardReviewAttentionBadgeKind) -> some View {
    DashboardReviewStatusPill(
      label: kind.label,
      tint: kind.tint,
      systemImage: kind.systemImage,
      isQuiet: true,
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

func dashboardReviewDisplayedTitle(
  _ title: String,
  hidesSemanticPrefix: Bool
) -> String {
  guard
    hidesSemanticPrefix,
    let match = dashboardReviewSemanticCommitPrefixExpression.firstMatch(
      in: title,
      range: NSRange(title.startIndex..<title.endIndex, in: title)
    ),
    let prefixRange = Range(match.range, in: title)
  else {
    return title
  }

  let stripped = title[prefixRange.upperBound...]
    .trimmingCharacters(in: .whitespacesAndNewlines)
  guard !stripped.isEmpty else { return title }
  return String(stripped)
}

private let dashboardReviewSemanticCommitPrefixExpression: NSRegularExpression = {
  let pattern =
    #"^(build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test)(?:\([^\r\n)]+\))?!?:\s+"#
  return try! NSRegularExpression(
    pattern: pattern,
    options: [.caseInsensitive]
  )
}()

private struct DashboardReviewAttentionBadgeStrip: View {
  let badges: DashboardReviewAttentionBadges

  var body: some View {
    HarnessMonitorWrapLayout(
      spacing: HarnessMonitorTheme.spacingXS,
      lineSpacing: HarnessMonitorTheme.spacingXS
    ) {
      ForEach(badges.kinds) { kind in
        badge(kind)
      }
    }
  }

  private func badge(_ kind: DashboardReviewAttentionBadgeKind) -> some View {
    DashboardReviewStatusPill(
      label: kind.label,
      tint: kind.tint,
      systemImage: kind.systemImage,
      isQuiet: true
    )
  }
}

private struct DashboardReviewVisibleRequiredFailedCheckNames {
  let visible: ArraySlice<String>
  let overflow: Int
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
