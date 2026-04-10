import SwiftUI
import Textual

enum HarnessMonitorMarkdownTextSelection {
  case disabled
  case enabled
}

struct HarnessMonitorMarkdownText: View {
  let markdown: String
  let font: Font
  let textSelection: HarnessMonitorMarkdownTextSelection

  @Environment(\.fontScale)
  private var fontScale

  init(
    _ markdown: String,
    font: Font = .body,
    textSelection: HarnessMonitorMarkdownTextSelection = .disabled
  ) {
    self.markdown = markdown
    self.font = font
    self.textSelection = textSelection
  }

  var body: some View {
    content
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityLabel(markdown)
  }

  private var baseContent: some View {
    StructuredText(markdown: markdown)
      .font(HarnessMonitorTextSize.scaledFont(font, by: fontScale))
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      .multilineTextAlignment(.leading)
      .textual.overflowMode(.wrap)
  }

  @ViewBuilder
  private var content: some View {
    switch textSelection {
    case .disabled:
      baseContent
    case .enabled:
      baseContent.textual.textSelection(.enabled)
    }
  }
}
