#if !HARNESS_FEATURE_TEXTUAL
  import SwiftUI

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

    @ViewBuilder private var content: some View {
      switch rendering {
      case .rich:
        richText
          .scaledFont(font)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .multilineTextAlignment(.leading)
          .modifier(MarkdownTextSelectionModifier(selection: textSelection))
      case .plainPreview:
        Text(verbatim: markdown)
          .scaledFont(font)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .multilineTextAlignment(.leading)
          .lineLimit(lineLimit)
      }
    }

    private var richText: Text {
      if let attributed = try? AttributedString(
        markdown: markdown,
        options: AttributedString.MarkdownParsingOptions(
          interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
      ) {
        return Text(attributed)
      }
      return Text(verbatim: markdown)
    }
  }

  private struct MarkdownTextSelectionModifier: ViewModifier {
    let selection: HarnessMonitorMarkdownTextSelection

    func body(content: Content) -> some View {
      switch selection {
      case .disabled:
        content
      case .enabled:
        content.textSelection(.enabled)
      }
    }
  }
#endif
