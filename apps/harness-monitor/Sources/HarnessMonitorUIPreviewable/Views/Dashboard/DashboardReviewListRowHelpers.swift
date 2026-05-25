import Foundation
import HarnessMonitorKit
import SwiftUI

// MARK: - Layout helpers

extension DashboardReviewListRow {
  var shouldRightAlignMetadataPills: Bool {
    !inlineIdentityAndAge.isEmpty
  }

  var titleContentLeadingInset: CGFloat {
    leadingStatusIndicatorWidth
      + HarnessMonitorTheme.spacingSM
      + (showsAvatars ? authorChipWidth + HarnessMonitorTheme.spacingSM : 0)
  }

  var showsLabelsStrip: Bool {
    showsLabels && !item.labels.isEmpty
  }

  var showsChangePill: Bool {
    showsLineCounters && (item.additions > 0 || item.deletions > 0)
  }

  var effectiveTitleMaximumLines: Int {
    if !wrapsTitle {
      return 1
    }
    return min(
      max(titleMaximumLines, DashboardReviewsPreferences.minimumRowTitleMaximumLines),
      DashboardReviewsPreferences.maximumRowTitleMaximumLines
    )
  }

  var estimatedTitleLineCount: Int {
    DashboardReviewListRowHeight.estimatedTitleLineCount(
      displayTitle,
      maximumLines: effectiveTitleMaximumLines
    )
  }

  var displayTitle: String {
    dashboardReviewDisplayedTitle(
      item.title,
      hidesSemanticPrefix: hidesSemanticPrefixesInTitle
    )
  }

  var titleAccessibilityLabel: String {
    let trimmedAuthorLogin = item.authorLogin.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !showsAvatars, !trimmedAuthorLogin.isEmpty else { return displayTitle }
    return "\(displayTitle), by @\(trimmedAuthorLogin)"
  }

  func rowMinimumHeight(
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
}

// MARK: - Static helpers

extension DashboardReviewListRow {
  /// Prepares the visible `#N · age` caption plus its verbose help label.
  /// The row body reads these labels multiple times, so keeping them as stored
  /// values avoids per-render array and join work across long review lists.
  static func makeInlineIdentityAndAgeLabels(
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

  static func makeVisibleRequiredFailedCheckNames(
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

  static func dashboardReviewAttentionBadgeKinds(
    for item: ReviewItem
  ) -> DashboardReviewAttentionBadges {
    DashboardReviewAttentionBadges(item: item)
  }
}

// MARK: - Free helpers

func dashboardReviewDisplayedTitle(
  _ title: String,
  hidesSemanticPrefix: Bool
) -> String {
  guard
    hidesSemanticPrefix,
    let match = prefixRegex.firstMatch(
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

private let prefixRegex: NSRegularExpression = {
  let pattern =
    #"^(build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test)(?:\([^\r\n)]+\))?!?:\s+"#
  guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
    fatalError("Invalid regex pattern: \(pattern)")
  }
  return regex
}()

// MARK: - Helper types

struct DashboardReviewAttentionBadgeStrip: View {
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

struct DashboardReviewRequiredFailedCheckStrip: View {
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
