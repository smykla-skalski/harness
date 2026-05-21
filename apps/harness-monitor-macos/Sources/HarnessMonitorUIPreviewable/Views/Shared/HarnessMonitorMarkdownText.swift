import SwiftUI

struct HarnessMonitorMarkdownText: View {
  private let markdown: String
  private let settings: HarnessMarkdownRenderSettings
  private let textSelection: HarnessMonitorMarkdownTextSelection
  private let rendering: HarnessMonitorMarkdownTextRendering
  private let lineLimit: Int?

  @Environment(\.fontScale)
  private var environmentFontScale
  @State private var document = HarnessMarkdownDocument.empty

  init(
    _ markdown: String,
    font: Font = .body,
    textSelection: HarnessMonitorMarkdownTextSelection = .disabled,
    rendering: HarnessMonitorMarkdownTextRendering = .rich,
    lineLimit: Int? = nil
  ) {
    self.markdown = markdown
    settings = HarnessMarkdownRenderSettings.default.withBodyFont(font)
    self.textSelection = textSelection
    self.rendering = rendering
    self.lineLimit = lineLimit
  }

  init(
    _ markdown: String,
    settings: HarnessMarkdownRenderSettings,
    textSelection: HarnessMonitorMarkdownTextSelection = .disabled,
    rendering: HarnessMonitorMarkdownTextRendering = .rich,
    lineLimit: Int? = nil
  ) {
    self.markdown = markdown
    self.settings = settings
    self.textSelection = textSelection
    self.rendering = rendering
    self.lineLimit = lineLimit
  }

  var body: some View {
    Group {
      switch rendering {
      case .plainPreview:
        Text(verbatim: markdown)
          .font(resolvedSettings.typography.body.font)
          .foregroundStyle(resolvedSettings.colors.text)
      case .rich:
        HarnessMarkdownDocumentView(
          document: document,
          settings: settings,
          style: resolvedSettings
        )
      }
    }
    .lineLimit(lineLimit)
    .modifier(MarkdownTextSelectionModifier(selection: textSelection))
    .task(id: renderKey) {
      await updateDocument()
    }
  }

  private var renderKey: HarnessMarkdownRenderKey {
    HarnessMarkdownRenderKey(markdown: markdown, rendering: rendering, lineLimit: lineLimit)
  }

  private var resolvedSettings: HarnessMarkdownResolvedRenderSettings {
    settings.resolved(environmentFontScale: environmentFontScale)
  }

  @MainActor
  private func updateDocument() async {
    guard rendering == .rich else { return }
    let key = renderKey
    if let cached = await HarnessMarkdownRenderCache.shared.document(for: key) {
      document = cached
      return
    }
    let source = markdown
    let worker = Task.detached(priority: .userInitiated) {
      HarnessMarkdownParser.parse(source, shouldCancel: { Task.isCancelled })
    }
    let parsed = await withTaskCancellationHandler {
      await worker.value
    } onCancel: {
      worker.cancel()
    }
    guard !Task.isCancelled else { return }
    await HarnessMarkdownRenderCache.shared.store(parsed, for: key)
    document = parsed
  }
}

private struct HarnessMarkdownDocumentView: View {
  let document: HarnessMarkdownDocument
  let settings: HarnessMarkdownRenderSettings
  let style: HarnessMarkdownResolvedRenderSettings

  var body: some View {
    HarnessMarkdownBlockStackView(
      blocks: document.blocks,
      settings: settings,
      style: style,
      spacing: style.spacing.documentBlock
    )
  }
}

private struct HarnessMarkdownBlockStackView: View {
  let blocks: [HarnessMarkdownBlock]
  let settings: HarnessMarkdownRenderSettings
  let style: HarnessMarkdownResolvedRenderSettings
  let spacing: CGFloat

  var body: some View {
    VStack(alignment: .leading, spacing: spacing) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        HarnessMarkdownBlockView(block: block, settings: settings, style: style)
          .padding(.top, style.spacing.blockSpacing(for: block).before)
          .padding(.bottom, style.spacing.blockSpacing(for: block).after)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct HarnessMarkdownBlockView: View {
  let block: HarnessMarkdownBlock
  let settings: HarnessMarkdownRenderSettings
  let style: HarnessMarkdownResolvedRenderSettings

  var body: some View {
    switch block {
    case .blockQuote(let blocks):
      HarnessMarkdownQuoteView(blocks: blocks, settings: settings, style: style)
    case .codeBlock(let language, let source, let tokens):
      HarnessMonitorCodeBlock(
        presentation: HarnessCodeBlockPresentation(
          source: source, language: language, tokens: tokens),
        settings: settings.codeBlock
      )
    case .details(let details):
      HarnessMarkdownDetailsView(details: details, settings: settings, style: style)
    case .heading(let level, let inlines):
      HarnessMarkdownInlineFlowView(
        inlines: inlines,
        style: inlineStyle(font: headingFont(level).font),
        images: style.images
      )
    case .html(let inlines):
      HarnessMarkdownParagraphView(
        inlines: inlines,
        style: style
      )
    case .orderedList(let start, let items):
      HarnessMarkdownListView(
        start: start, ordered: true, items: items, settings: settings, style: style)
    case .paragraph(let inlines):
      HarnessMarkdownParagraphView(
        inlines: inlines,
        style: style
      )
    case .table(let table):
      HarnessMarkdownTableView(table: table, settings: settings, style: style)
    case .thematicBreak:
      Divider()
        .overlay(style.colors.thematicBreak)
    case .unorderedList(let items):
      HarnessMarkdownListView(
        start: 1, ordered: false, items: items, settings: settings, style: style)
    }
  }

  private func inlineStyle(font: Font) -> HarnessMarkdownInlineRenderStyle {
    HarnessMarkdownInlineRenderStyle(
      font: font,
      codeFont: style.typography.inlineCode.font,
      colors: style.colors
    )
  }

  private func headingFont(_ level: Int) -> HarnessMarkdownResolvedFontStyle {
    switch level {
    case 1:
      style.typography.heading1
    case 2:
      style.typography.heading2
    case 3:
      style.typography.heading3
    default:
      style.typography.headingDefault
    }
  }
}

private struct HarnessMarkdownDetailsView: View {
  let details: HarnessMarkdownDetails
  let settings: HarnessMarkdownRenderSettings
  let style: HarnessMarkdownResolvedRenderSettings

  @State private var isExpanded: Bool

  init(
    details: HarnessMarkdownDetails,
    settings: HarnessMarkdownRenderSettings,
    style: HarnessMarkdownResolvedRenderSettings
  ) {
    self.details = details
    self.settings = settings
    self.style = style
    _isExpanded = State(initialValue: details.isOpen)
  }

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      HarnessMarkdownBlockStackView(
        blocks: details.blocks,
        settings: settings,
        style: style,
        spacing: style.spacing.nestedBlock
      )
      .padding(.leading, style.spacing.detailsContentIndent)
    } label: {
      HarnessMarkdownInlineFlowView(
        inlines: details.summary,
        style: HarnessMarkdownInlineRenderStyle(
          font: style.typography.body.font,
          codeFont: style.typography.inlineCode.font,
          colors: style.colors
        ),
        images: style.images,
        imageLayout: .inline
      )
    }
  }
}

private struct HarnessMarkdownQuoteView: View {
  let blocks: [HarnessMarkdownBlock]
  let settings: HarnessMarkdownRenderSettings
  let style: HarnessMarkdownResolvedRenderSettings

  var body: some View {
    HStack(alignment: .top, spacing: style.spacing.quoteContentGap) {
      Rectangle()
        .fill(style.colors.quoteBar)
        .frame(width: 3)
      HarnessMarkdownBlockStackView(
        blocks: blocks,
        settings: settings,
        style: style,
        spacing: style.spacing.nestedBlock
      )
    }
  }
}

private struct HarnessMarkdownListView: View {
  let start: Int
  let ordered: Bool
  let items: [HarnessMarkdownListItem]
  let settings: HarnessMarkdownRenderSettings
  let style: HarnessMarkdownResolvedRenderSettings

  var body: some View {
    VStack(alignment: .leading, spacing: style.spacing.listItem) {
      ForEach(visibleItems, id: \.offset) { index, item in
        HStack(alignment: .firstTextBaseline, spacing: style.spacing.listMarkerGap) {
          marker(for: item, index: index)
            .frame(width: 28, alignment: .trailing)
          HarnessMarkdownBlockStackView(
            blocks: item.blocks,
            settings: settings,
            style: style,
            spacing: style.spacing.listItemContent
          )
        }
      }
    }
  }

  private var visibleItems: [(offset: Int, item: HarnessMarkdownListItem)] {
    items.enumerated().compactMap { offset, item in
      guard item.rendersListRow else { return nil }
      return (offset: offset, item: item)
    }
  }

  @ViewBuilder
  private func marker(for item: HarnessMarkdownListItem, index: Int) -> some View {
    if let checkbox = item.checkbox {
      Toggle(isOn: .constant(checkbox)) {
        EmptyView()
      }
      .toggleStyle(.checkbox)
      .labelsHidden()
      .controlSize(.small)
      .allowsHitTesting(false)
      .alignmentGuide(.firstTextBaseline) { dimensions in
        dimensions[VerticalAlignment.center]
      }
    } else if ordered {
      Text("\(start + index).")
        .font(style.typography.listMarker.font)
        .foregroundStyle(style.colors.secondaryText)
    } else {
      Text("•")
        .font(style.typography.listMarker.font)
        .foregroundStyle(style.colors.secondaryText)
    }
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
