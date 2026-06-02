import Foundation
import HarnessMonitorKit
import SwiftUI

// MARK: - Layout helpers

extension DashboardReviewListRow {
  var shouldRightAlignMetadataPills: Bool {
    !inlineIdentityAndAge.isEmpty
  }

  var titleContentLeadingInset: CGFloat {
    return showsAvatars ? authorChipWidth + HarnessMonitorTheme.spacingSM : 0
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

  var titleAccessibilityLabel: String {
    let trimmedAuthorLogin = item.authorLogin.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !showsAvatars, !trimmedAuthorLogin.isEmpty else { return titleAccessibilityText }
    return "\(titleAccessibilityText), by @\(trimmedAuthorLogin)"
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
    for item: ReviewItem,
    slaThresholdHours: Int? = nil
  ) -> DashboardReviewAttentionBadges {
    DashboardReviewAttentionBadges(item: item, slaThresholdHours: slaThresholdHours)
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

func dashboardReviewInlineTitleInlines(_ title: String) -> [HarnessMarkdownInline]? {
  guard title.contains("`") else { return nil }

  var inlines: [HarnessMarkdownInline] = []
  inlines.reserveCapacity(4)

  let endIndex = title.endIndex
  var textStart = title.startIndex
  var index = title.startIndex
  var foundInlineCode = false

  while index < endIndex {
    guard title[index] == "`" else {
      index = title.index(after: index)
      continue
    }

    let codeStart = title.index(after: index)
    guard
      codeStart < endIndex,
      let codeEnd = title[codeStart...].firstIndex(of: "`"),
      codeEnd > codeStart
    else {
      index = codeStart
      continue
    }

    if textStart < index {
      inlines.append(.text(String(title[textStart..<index])))
    }
    inlines.append(.code(String(title[codeStart..<codeEnd])))
    foundInlineCode = true
    textStart = title.index(after: codeEnd)
    index = textStart
  }

  if textStart < endIndex {
    inlines.append(.text(String(title[textStart...])))
  }

  return foundInlineCode ? inlines : nil
}

func dashboardReviewInlineTitlePlainText(_ inlines: [HarnessMarkdownInline]) -> String {
  inlines.reduce(into: "") { result, inline in
    switch inline {
    case .code(let value), .text(let value):
      result += value
    case .autolink(let value):
      result += value
    case .emphasis(let children), .strikethrough(let children), .strong(let children):
      result += dashboardReviewInlineTitlePlainText(children)
    case .image(let image):
      result += image.alt
    case .link(let label, _, _):
      result += dashboardReviewInlineTitlePlainText(label)
    case .lineBreak:
      result += "\n"
    case .softBreak:
      result += " "
    }
  }
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
