import HarnessMonitorKit
import SwiftUI

/// Split-view diff with left (old) and right (new) panes side by side.
/// Falls back to the unified renderer when the proposed width is below
/// `minColumnPoints`. Both panes consume tokens produced once by
/// `SyntaxHighlightCache` and split into left/right sides at render
/// time.
struct DashboardReviewFileDiffSplit: View {
  let patch: ReviewFilePatch
  let language: HarnessReviewFileLanguage
  var minColumnPoints: CGFloat = 280

  @State private var leftText: AttributedString?
  @State private var rightText: AttributedString?

  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      if width / 2 < minColumnPoints {
        DashboardReviewFileDiffUnified(patch: patch, language: language)
      } else {
        HStack(alignment: .top, spacing: 8) {
          column(text: leftText ?? AttributedString(patch.patch))
          Divider()
          column(text: rightText ?? AttributedString(patch.patch))
        }
      }
    }
    .frame(minHeight: 80)
    .accessibilityIdentifier("dashboardReviewFileDiffSplit")
    .task(id: patch.patch) {
      let tokens = await SyntaxHighlightCache.shared.tokenize(patch.patch, language: .diff)
      leftText = Self.attributedColumn(tokens: tokens, includeAdditions: false)
      rightText = Self.attributedColumn(tokens: tokens, includeAdditions: true)
    }
  }

  private func column(text: AttributedString) -> some View {
    ScrollView(.horizontal) {
      Text(text)
        .font(.system(size: 12, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  static func attributedColumn(
    tokens: [HarnessCodeToken],
    includeAdditions: Bool
  ) -> AttributedString {
    var result = AttributedString()
    for token in tokens {
      switch token.kind {
      case .inserted where !includeAdditions: continue
      case .deleted where includeAdditions: continue
      default:
        var fragment = AttributedString(token.text)
        switch token.kind {
        case .inserted:
          fragment.backgroundColor = .green.opacity(0.15)
          fragment.foregroundColor = .primary
        case .deleted:
          fragment.backgroundColor = .red.opacity(0.15)
          fragment.foregroundColor = .primary
        case .heading:
          fragment.foregroundColor = .secondary
        default:
          fragment.foregroundColor = .primary
        }
        result += fragment
      }
    }
    return result
  }
}
