import HarnessMonitorKit
import SwiftUI

struct SearchHighlightedText: View, Equatable {
  let text: String
  let highlights: [SearchHighlightRange]

  @ViewBuilder var body: some View {
    if highlights.isEmpty {
      Text(text)
    } else {
      Text(attributedText)
    }
  }

  private var attributedText: AttributedString {
    var rendered = AttributedString(text)
    for highlight in highlights {
      guard let range = highlight.stringRange(in: text) else { continue }
      guard
        let lower = AttributedString.Index(range.lowerBound, within: rendered),
        let upper = AttributedString.Index(range.upperBound, within: rendered)
      else {
        continue
      }
      rendered[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
      rendered[lower..<upper].foregroundColor = HarnessMonitorTheme.accent
    }
    return rendered
  }
}
