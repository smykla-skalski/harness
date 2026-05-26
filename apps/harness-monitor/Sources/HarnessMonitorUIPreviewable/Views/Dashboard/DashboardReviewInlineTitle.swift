import HarnessMonitorKit
import SwiftUI

/// Shared PR-title renderer for the Reviews surfaces. Backtick-wrapped runs
/// render as inline code spans using the canonical theme styling
/// (`HarnessMarkdownColorSettings.default`), so the inline-code look stays
/// identical across the detail header, the Files header, and the list row.
/// Titles without backticks fall back to a plain styled `Text`.
///
/// `font` and `codeFont` are base text styles; the view scales them by the
/// ambient `\.fontScale` exactly like the `scaledFont(_:)` modifier.
struct DashboardReviewInlineTitle: View {
  let title: String
  let hidesSemanticPrefix: Bool
  let font: Font
  let codeFont: Font
  var foreground: Color = HarnessMonitorTheme.ink

  @Environment(\.fontScale)
  private var fontScale

  var displayTitle: String {
    dashboardReviewDisplayedTitle(title, hidesSemanticPrefix: hidesSemanticPrefix)
  }

  var inlines: [HarnessMarkdownInline]? {
    dashboardReviewInlineTitleInlines(displayTitle)
  }

  var accessibilityText: String {
    inlines.map(dashboardReviewInlineTitlePlainText) ?? displayTitle
  }

  var body: some View {
    if let inlines {
      Text(
        HarnessMarkdownInlineRenderer.attributedString(
          from: inlines,
          style: HarnessMarkdownInlineRenderStyle(
            font: HarnessMonitorTextSize.scaledFont(font, by: fontScale),
            codeFont: HarnessMonitorTextSize.scaledFont(codeFont, by: fontScale),
            colors: .default
          )
        )
      )
      .accessibilityLabel(accessibilityText)
    } else {
      Text(displayTitle)
        .font(HarnessMonitorTextSize.scaledFont(font, by: fontScale))
        .foregroundStyle(foreground)
    }
  }
}
