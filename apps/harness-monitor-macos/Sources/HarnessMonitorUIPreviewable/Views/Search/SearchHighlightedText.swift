import HarnessMonitorKit
import SwiftUI

struct SearchHighlightedText: View, Equatable {
  let text: String
  let highlights: [SearchHighlightRange]

  var body: some View {
    Text(attributedText)
  }

  private var attributedText: AttributedString {
    var rendered = AttributedString(text)
    for range in highlights.compactMap({ $0.stringRange(in: text) }) {
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
