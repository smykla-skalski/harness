import SwiftUI
import Textual

enum HarnessMonitorMarkdownTextSelection {
  case disabled
  case enabled
}

enum HarnessMonitorMarkdownTextRendering {
  case rich
  case plainPreview
}

struct HarnessMonitorMarkdownText: View {
  let markdown: String
  let font: Font
  let textSelection: HarnessMonitorMarkdownTextSelection
  let rendering: HarnessMonitorMarkdownTextRendering
  let lineLimit: Int?

  @Environment(\.fontScale)
  private var fontScale

  init(
    _ markdown: String,
    font: Font = .body,
    textSelection: HarnessMonitorMarkdownTextSelection = .disabled,
    rendering: HarnessMonitorMarkdownTextRendering = .rich,
    lineLimit: Int? = nil
  ) {
    self.markdown = markdown
    self.font = font
    self.textSelection = textSelection
    self.rendering = rendering
    self.lineLimit = lineLimit
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
      .textual.inlineStyle(.harnessMonitorMarkdown)
      .textual.headingStyle(HarnessMonitorMarkdownHeadingStyle())
      .textual.paragraphStyle(HarnessMonitorMarkdownParagraphStyle())
      .textual.blockQuoteStyle(HarnessMonitorMarkdownBlockQuoteStyle())
      .textual.codeBlockStyle(HarnessMonitorMarkdownCodeBlockStyle())
      .textual.unorderedListMarker(HarnessMonitorMarkdownUnorderedListMarker())
      .textual.orderedListMarker(HarnessMonitorMarkdownOrderedListMarker())
      .textual.overflowMode(.wrap)
  }

  @ViewBuilder private var content: some View {
    switch rendering {
    case .rich:
      switch textSelection {
      case .disabled:
        baseContent
      case .enabled:
        baseContent.textual.textSelection(.enabled)
      }
    case .plainPreview:
      Text(verbatim: markdown)
        .scaledFont(font)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .multilineTextAlignment(.leading)
        .lineLimit(lineLimit)
    }
  }
}

extension InlineStyle {
  fileprivate static var harnessMonitorMarkdown: InlineStyle {
    InlineStyle()
      .code(
        .monospaced,
        .fontScale(0.92),
        .foregroundColor(HarnessMonitorTheme.ink),
        .backgroundColor(HarnessMonitorTheme.accent.opacity(0.10))
      )
      .strong(.fontWeight(.semibold), .foregroundColor(HarnessMonitorTheme.ink))
      .link(
        .foregroundColor(HarnessMonitorTheme.accent),
        .underlineStyle(.single)
      )
  }
}

private struct HarnessMonitorMarkdownHeadingStyle: StructuredText.HeadingStyle {
  private static let fontScales: [CGFloat] = [1.16, 1.10, 1.04, 1.0, 0.96, 0.94]

  func makeBody(configuration: Configuration) -> some View {
    let headingLevel = min(max(configuration.headingLevel, 1), 6)

    configuration.label
      .foregroundStyle(HarnessMonitorTheme.ink)
      .fontWeight(headingLevel <= 2 ? .bold : .semibold)
      .textual.fontScale(Self.fontScales[headingLevel - 1])
      .textual.lineSpacing(.fontScaled(0.12))
      .textual.blockSpacing(.fontScaled(top: 0.55, bottom: 0.25))
  }
}

private struct HarnessMonitorMarkdownParagraphStyle: StructuredText.ParagraphStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      .textual.lineSpacing(.fontScaled(0.18))
      .textual.blockSpacing(.fontScaled(top: 0.35))
  }
}

private struct HarnessMonitorMarkdownBlockQuoteStyle: StructuredText.BlockQuoteStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .fill(HarnessMonitorTheme.accent.opacity(0.65))
        .frame(width: 3)
      configuration.label
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      HarnessMonitorTheme.accent.opacity(0.07),
      in: RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
    )
    .textual.blockSpacing(.fontScaled(top: 0.55, bottom: 0.2))
  }
}

private struct HarnessMonitorMarkdownCodeBlockStyle: StructuredText.CodeBlockStyle {
  @Environment(\.fontScale)
  private var fontScale

  func makeBody(configuration: Configuration) -> some View {
    Overflow {
      configuration.label
        .font(HarnessMonitorTextSize.scaledFont(.caption.monospaced(), by: fontScale))
        .foregroundStyle(HarnessMonitorTheme.ink)
        .textual.lineSpacing(.fontScaled(0.20))
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, HarnessMonitorTheme.spacingSM)
        .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    }
    .background(
      HarnessMonitorTheme.ink.opacity(0.06),
      in: RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
        .stroke(HarnessMonitorTheme.controlBorder.opacity(0.55), lineWidth: 1)
    }
    .textual.blockSpacing(.fontScaled(top: 0.55, bottom: 0.2))
  }
}

private struct HarnessMonitorMarkdownUnorderedListMarker: StructuredText.UnorderedListMarker {
  func makeBody(configuration _: Configuration) -> some View {
    Image(systemName: "circle.fill")
      .foregroundStyle(HarnessMonitorTheme.accent)
      .textual.fontScale(0.32)
      .textual.frame(
        width: .fontScaled(1.35),
        height: .fontScaled(1.0),
        alignment: .center
      )
  }
}

private struct HarnessMonitorMarkdownOrderedListMarker: StructuredText.OrderedListMarker {
  func makeBody(configuration: Configuration) -> some View {
    Text("\(configuration.ordinal).")
      .monospacedDigit()
      .foregroundStyle(HarnessMonitorTheme.accent)
      .fontWeight(.semibold)
      .textual.fontScale(0.94)
      .textual.frame(
        width: .fontScaled(1.35),
        height: .fontScaled(1.0),
        alignment: .center
      )
  }
}
