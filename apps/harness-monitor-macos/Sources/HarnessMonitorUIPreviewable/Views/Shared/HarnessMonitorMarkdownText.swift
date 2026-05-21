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
    let renderableBlocks = visibleBlocks
    VStack(alignment: .leading, spacing: spacing) {
      ForEach(Array(renderableBlocks.enumerated()), id: \.element.offset) { visibleIndex, entry in
        let blockSpacing = style.spacing.blockSpacing(for: entry.block)
        HarnessMarkdownBlockView(block: entry.block, settings: settings, style: style)
          .padding(.top, visibleIndex == 0 ? 0 : blockSpacing.before)
          .padding(.bottom, visibleIndex == renderableBlocks.count - 1 ? 0 : blockSpacing.after)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var visibleBlocks: [(offset: Int, block: HarnessMarkdownBlock)] {
    blocks.enumerated().compactMap { offset, block in
      guard !isSuppressedThematicBreak(at: offset) else { return nil }
      return (offset: offset, block: block)
    }
  }

  private func isSuppressedThematicBreak(at index: Int) -> Bool {
    guard case .thematicBreak = blocks[index], index + 1 < blocks.count else { return false }
    if case .heading = blocks[index + 1] {
      return true
    }
    return false
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
    let metrics = HarnessMarkdownMarkerMetrics(style: style)
    VStack(alignment: .leading, spacing: style.spacing.nestedBlock) {
      Button {
        isExpanded.toggle()
      } label: {
        HStack(alignment: .firstTextBaseline, spacing: metrics.gap) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: metrics.chevronSize, weight: .semibold))
            .foregroundStyle(style.colors.secondaryText)
            .frame(
              width: metrics.chevronColumnWidth,
              height: metrics.firstLineHeight,
              alignment: .center
            )
            .alignmentGuide(.firstTextBaseline) { dimensions in
              dimensions[VerticalAlignment.center] + metrics.firstLineCenterBaselineOffset
            }
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
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .harnessPlainButtonStyle()
      .frame(maxWidth: .infinity, alignment: .leading)
      .modifier(HarnessMarkdownPointerHoverModifier(color: style.colors.link))
      .accessibilityLabel(Text(HarnessMarkdownInlinePlainText.string(from: details.summary)))
      .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

      if isExpanded {
        detailsContent
      }
    }
  }

  private var detailsContent: some View {
    HarnessMarkdownBlockStackView(
      blocks: details.blocks,
      settings: settings,
      style: style,
      spacing: style.spacing.nestedBlock
    )
    .padding(.leading, style.spacing.detailsContentIndent)
  }
}

private enum HarnessMarkdownInlinePlainText {
  static func string(from inlines: [HarnessMarkdownInline]) -> String {
    inlines.map { text(for: $0) }.joined()
  }

  private static func text(for inline: HarnessMarkdownInline) -> String {
    switch inline {
    case .autolink(let destination):
      decodeEntities(destination)
    case .code(let value), .text(let value):
      decodeEntities(value)
    case .emphasis(let children), .strikethrough(let children), .strong(let children):
      string(from: children)
    case .image(let image):
      image.alt.isEmpty ? image.source : image.alt
    case .lineBreak, .softBreak:
      " "
    case .link(let label, _, _):
      string(from: label)
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
    let metrics = HarnessMarkdownMarkerMetrics(style: style)
    VStack(alignment: .leading, spacing: style.spacing.listItem) {
      ForEach(visibleItems, id: \.offset) { index, item in
        HStack(alignment: .firstTextBaseline, spacing: metrics.gap) {
          marker(for: item, index: index, metrics: metrics)
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
  private func marker(
    for item: HarnessMarkdownListItem,
    index: Int,
    metrics: HarnessMarkdownMarkerMetrics
  ) -> some View {
    if let checkbox = item.checkbox {
      Toggle(isOn: .constant(checkbox)) {
        EmptyView()
      }
      .toggleStyle(.checkbox)
      .labelsHidden()
      .controlSize(.small)
      .allowsHitTesting(false)
      .frame(width: metrics.columnWidth, height: metrics.firstLineHeight, alignment: .center)
      .alignmentGuide(.firstTextBaseline) { dimensions in
        dimensions[VerticalAlignment.center] + metrics.firstLineCenterBaselineOffset
      }
    } else if ordered {
      Text("\(start + index).")
        .font(style.typography.listMarker.font)
        .foregroundStyle(style.colors.secondaryText)
        .frame(width: metrics.columnWidth, height: metrics.firstLineHeight, alignment: .trailing)
        .alignmentGuide(.firstTextBaseline) { dimensions in
          dimensions[VerticalAlignment.center] + metrics.firstLineCenterBaselineOffset
        }
    } else {
      Text("•")
        .font(style.typography.listMarker.font)
        .foregroundStyle(style.colors.secondaryText)
        .frame(width: metrics.columnWidth, height: metrics.firstLineHeight, alignment: .center)
        .alignmentGuide(.firstTextBaseline) { dimensions in
          dimensions[VerticalAlignment.center] + metrics.firstLineCenterBaselineOffset
        }
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
