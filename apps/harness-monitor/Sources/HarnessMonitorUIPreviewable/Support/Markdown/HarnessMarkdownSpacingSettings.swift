import SwiftUI

struct HarnessMarkdownBlockSpacing: Equatable {
  var before: CGFloat
  var after: CGFloat

  static let none = Self(before: 0, after: 0)

  func scaled(by scale: CGFloat) -> Self {
    Self(before: max(0, before * scale), after: max(0, after * scale))
  }
}

struct HarnessMarkdownSpacingSettings: Equatable {
  var documentBlock: CGFloat
  var paragraph: HarnessMarkdownBlockSpacing
  var heading: HarnessMarkdownBlockSpacing
  var blockQuote: HarnessMarkdownBlockSpacing
  var codeBlock: HarnessMarkdownBlockSpacing
  var details: HarnessMarkdownBlockSpacing
  var list: HarnessMarkdownBlockSpacing
  var table: HarnessMarkdownBlockSpacing
  var thematicBreak: HarnessMarkdownBlockSpacing
  var nestedBlock: CGFloat
  var detailsContentIndent: CGFloat
  var detailsMaxHeight: CGFloat
  var listItem: CGFloat
  var listItemContent: CGFloat
  var listMarkerGap: CGFloat
  var listSymbolWidth: CGFloat
  var listMarkerWidth: CGFloat
  var quoteContentGap: CGFloat
  var alertBottomMargin: CGFloat
  var tableColumn: CGFloat
  var tableRow: CGFloat

  static let `default` = Self(
    documentBlock: HarnessMonitorTheme.spacingSM,
    paragraph: .none,
    heading: HarnessMarkdownBlockSpacing(before: 16, after: 8),
    blockQuote: .none,
    codeBlock: .none,
    details: .none,
    list: .none,
    table: .none,
    thematicBreak: .none,
    nestedBlock: HarnessMonitorTheme.spacingXS,
    detailsContentIndent: HarnessMonitorTheme.spacingSM,
    detailsMaxHeight: 420,
    listItem: HarnessMonitorTheme.spacingXS,
    listItemContent: HarnessMonitorTheme.spacingXS,
    listMarkerGap: 6,
    listSymbolWidth: 6,
    listMarkerWidth: 20,
    quoteContentGap: HarnessMonitorTheme.spacingSM,
    alertBottomMargin: HarnessMonitorTheme.spacingSM,
    tableColumn: HarnessMonitorTheme.spacingMD,
    tableRow: HarnessMonitorTheme.spacingXS
  )

  func scaled(by scale: CGFloat) -> Self {
    Self(
      documentBlock: scaled(documentBlock, by: scale),
      paragraph: paragraph.scaled(by: scale),
      heading: heading.scaled(by: scale),
      blockQuote: blockQuote.scaled(by: scale),
      codeBlock: codeBlock.scaled(by: scale),
      details: details.scaled(by: scale),
      list: list.scaled(by: scale),
      table: table.scaled(by: scale),
      thematicBreak: thematicBreak.scaled(by: scale),
      nestedBlock: scaled(nestedBlock, by: scale),
      detailsContentIndent: scaled(detailsContentIndent, by: scale),
      detailsMaxHeight: max(120, scaled(detailsMaxHeight, by: scale)),
      listItem: scaled(listItem, by: scale),
      listItemContent: scaled(listItemContent, by: scale),
      listMarkerGap: scaled(listMarkerGap, by: scale),
      listSymbolWidth: scaled(listSymbolWidth, by: scale),
      listMarkerWidth: scaled(listMarkerWidth, by: scale),
      quoteContentGap: scaled(quoteContentGap, by: scale),
      alertBottomMargin: scaled(alertBottomMargin, by: scale),
      tableColumn: scaled(tableColumn, by: scale),
      tableRow: scaled(tableRow, by: scale)
    )
  }

  func blockSpacing(for block: HarnessMarkdownBlock) -> HarnessMarkdownBlockSpacing {
    switch block {
    case .alert:
      blockQuote
    case .blockQuote:
      blockQuote
    case .codeBlock:
      codeBlock
    case .details:
      details
    case .heading:
      heading
    case .html, .paragraph:
      paragraph
    case .orderedList, .unorderedList:
      list
    case .table:
      table
    case .thematicBreak:
      thematicBreak
    }
  }

  private func scaled(_ value: CGFloat, by scale: CGFloat) -> CGFloat {
    max(0, value * scale)
  }
}
