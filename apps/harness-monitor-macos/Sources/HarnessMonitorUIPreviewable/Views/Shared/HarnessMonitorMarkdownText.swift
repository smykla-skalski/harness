import SwiftUI

struct HarnessMonitorMarkdownText: View {
  private let markdown: String
  private let font: Font
  private let textSelection: HarnessMonitorMarkdownTextSelection
  private let rendering: HarnessMonitorMarkdownTextRendering
  private let lineLimit: Int?

  @State private var document = HarnessMarkdownDocument.empty

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
    Group {
      switch rendering {
      case .plainPreview:
        Text(verbatim: markdown)
          .scaledFont(font)
      case .rich:
        HarnessMarkdownDocumentView(document: document, font: font)
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

  @MainActor
  private func updateDocument() async {
    guard rendering == .rich else { return }
    let key = renderKey
    if let cached = await HarnessMarkdownRenderCache.shared.document(for: key) {
      document = cached
      return
    }
    let source = markdown
    let parsed = await Task.detached(priority: .userInitiated) {
      HarnessMarkdownParser.parse(source)
    }.value
    guard !Task.isCancelled else { return }
    await HarnessMarkdownRenderCache.shared.store(parsed, for: key)
    document = parsed
  }
}

private struct HarnessMarkdownDocumentView: View {
  let document: HarnessMarkdownDocument
  let font: Font

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
        HarnessMarkdownBlockView(block: block, font: font)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct HarnessMarkdownBlockView: View {
  let block: HarnessMarkdownBlock
  let font: Font

  var body: some View {
    switch block {
    case .blockQuote(let blocks):
      HarnessMarkdownQuoteView(blocks: blocks, font: font)
    case .codeBlock(let language, let source, let tokens):
      HarnessMonitorCodeBlock(
        presentation: HarnessCodeBlockPresentation(source: source, language: language, tokens: tokens)
      )
    case .heading(let level, let inlines):
      Text(HarnessMarkdownInlineRenderer.attributedString(from: inlines, font: headingFont(level)))
        .fixedSize(horizontal: false, vertical: true)
    case .html(let html):
      Text(verbatim: html)
        .scaledFont(font.monospaced())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .fixedSize(horizontal: false, vertical: true)
    case .orderedList(let start, let items):
      HarnessMarkdownListView(start: start, ordered: true, items: items, font: font)
    case .paragraph(let inlines):
      Text(HarnessMarkdownInlineRenderer.attributedString(from: inlines, font: font))
        .fixedSize(horizontal: false, vertical: true)
    case .table(let table):
      HarnessMarkdownTableView(table: table, font: font)
    case .thematicBreak:
      Divider()
    case .unorderedList(let items):
      HarnessMarkdownListView(start: 1, ordered: false, items: items, font: font)
    }
  }

  private func headingFont(_ level: Int) -> Font {
    switch level {
    case 1:
      .title2.weight(.semibold)
    case 2:
      .title3.weight(.semibold)
    case 3:
      .headline
    default:
      .subheadline.weight(.semibold)
    }
  }
}

private struct HarnessMarkdownQuoteView: View {
  let blocks: [HarnessMarkdownBlock]
  let font: Font

  var body: some View {
    HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
      Rectangle()
        .fill(HarnessMonitorTheme.controlBorder)
        .frame(width: 3)
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
          HarnessMarkdownBlockView(block: block, font: font)
        }
      }
    }
  }
}

private struct HarnessMarkdownListView: View {
  let start: Int
  let ordered: Bool
  let items: [HarnessMarkdownListItem]
  let font: Font

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      ForEach(items.indices, id: \.self) { index in
        HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
          marker(for: items[index], index: index)
            .frame(width: 28, alignment: .trailing)
          VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
            ForEach(Array(items[index].blocks.enumerated()), id: \.offset) { _, block in
              HarnessMarkdownBlockView(block: block, font: font)
            }
          }
        }
      }
    }
  }

  private func marker(for item: HarnessMarkdownListItem, index: Int) -> Text {
    if let checkbox = item.checkbox {
      return Text(checkbox ? "[x]" : "[ ]")
    }
    if ordered {
      return Text("\(start + index).")
    }
    return Text("•")
  }
}

private struct HarnessMarkdownTableView: View {
  let table: HarnessMarkdownTable
  let font: Font

  var body: some View {
    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: HarnessMonitorTheme.spacingMD) {
      row(cells: table.headers, isHeader: true)
      Divider()
      ForEach(table.rows.indices, id: \.self) { index in
        row(cells: table.rows[index], isHeader: false)
      }
    }
    .padding(HarnessMonitorTheme.spacingSM)
    .background {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
        .fill(HarnessMonitorTheme.ink.opacity(0.04))
    }
    .overlay {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
        .stroke(HarnessMonitorTheme.controlBorder.opacity(0.5), lineWidth: 1)
    }
  }

  @ViewBuilder
  private func row(cells: [[HarnessMarkdownInline]], isHeader: Bool) -> some View {
    GridRow {
      ForEach(cells.indices, id: \.self) { index in
        Text(
          HarnessMarkdownInlineRenderer.attributedString(
            from: cells[index],
            font: isHeader ? font.weight(.semibold) : font
          )
        )
        .fixedSize(horizontal: false, vertical: true)
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
