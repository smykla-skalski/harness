import SwiftUI

extension HarnessMarkdownUserSettings {
  struct Spacing: Codable, Equatable {
    var documentBlock = 8.0
    var paragraphBefore = 0.0
    var paragraphAfter = 0.0
    var headingBefore = 16.0
    var headingAfter = 8.0
    var blockQuoteBefore = 0.0
    var blockQuoteAfter = 0.0
    var codeBlockBefore = 0.0
    var codeBlockAfter = 0.0
    var detailsBefore = 0.0
    var detailsAfter = 0.0
    var listBefore = 0.0
    var listAfter = 0.0
    var tableBefore = 0.0
    var tableAfter = 0.0
    var thematicBreakBefore = 0.0
    var thematicBreakAfter = 0.0
    var nestedBlock = 4.0
    var detailsContentIndent = 8.0
    var detailsMaxHeight = 420.0
    var listItem = 4.0
    var listItemContent = 4.0
    var listMarkerGap = 6.0
    var listSymbolWidth = 6.0
    var listMarkerWidth = 20.0
    var quoteContentGap = 8.0
    var alertBottomMargin = 8.0
    var tableColumn = 12.0
    var tableRow = 4.0

    private enum CodingKeys: String, CodingKey {
      case documentBlock
      case paragraphBefore
      case paragraphAfter
      case headingBefore
      case headingAfter
      case blockQuoteBefore
      case blockQuoteAfter
      case codeBlockBefore
      case codeBlockAfter
      case detailsBefore
      case detailsAfter
      case listBefore
      case listAfter
      case tableBefore
      case tableAfter
      case thematicBreakBefore
      case thematicBreakAfter
      case nestedBlock
      case detailsContentIndent
      case detailsMaxHeight
      case listItem
      case listItemContent
      case listMarkerGap
      case listSymbolWidth
      case listMarkerWidth
      case quoteContentGap
      case alertBottomMargin
      case tableColumn
      case tableRow
    }

    var settings: HarnessMarkdownSpacingSettings {
      HarnessMarkdownSpacingSettings(
        documentBlock: CGFloat(max(0, documentBlock)),
        paragraph: blockSpacing(before: paragraphBefore, after: paragraphAfter),
        heading: blockSpacing(before: headingBefore, after: headingAfter),
        blockQuote: blockSpacing(before: blockQuoteBefore, after: blockQuoteAfter),
        codeBlock: blockSpacing(before: codeBlockBefore, after: codeBlockAfter),
        details: blockSpacing(before: detailsBefore, after: detailsAfter),
        list: blockSpacing(before: listBefore, after: listAfter),
        table: blockSpacing(before: tableBefore, after: tableAfter),
        thematicBreak: blockSpacing(before: thematicBreakBefore, after: thematicBreakAfter),
        nestedBlock: CGFloat(max(0, nestedBlock)),
        detailsContentIndent: CGFloat(max(0, detailsContentIndent)),
        detailsMaxHeight: CGFloat(max(120, detailsMaxHeight)),
        listItem: CGFloat(max(0, listItem)),
        listItemContent: CGFloat(max(0, listItemContent)),
        listMarkerGap: CGFloat(max(0, listMarkerGap)),
        listSymbolWidth: CGFloat(max(0, listSymbolWidth)),
        listMarkerWidth: CGFloat(max(0, listMarkerWidth)),
        quoteContentGap: CGFloat(max(0, quoteContentGap)),
        alertBottomMargin: CGFloat(max(0, alertBottomMargin)),
        tableColumn: CGFloat(max(0, tableColumn)),
        tableRow: CGFloat(max(0, tableRow))
      )
    }

    private func blockSpacing(before: Double, after: Double) -> HarnessMarkdownBlockSpacing {
      HarnessMarkdownBlockSpacing(before: CGFloat(max(0, before)), after: CGFloat(max(0, after)))
    }

    init() {}

    init(from decoder: Decoder) throws {
      self.init()
      let values = try decoder.container(keyedBy: CodingKeys.self)
      documentBlock =
        try values.decodeIfPresent(Double.self, forKey: .documentBlock) ?? documentBlock
      paragraphBefore =
        try values.decodeIfPresent(Double.self, forKey: .paragraphBefore) ?? paragraphBefore
      paragraphAfter =
        try values.decodeIfPresent(Double.self, forKey: .paragraphAfter) ?? paragraphAfter
      headingBefore =
        try values.decodeIfPresent(Double.self, forKey: .headingBefore) ?? headingBefore
      headingAfter = try values.decodeIfPresent(Double.self, forKey: .headingAfter) ?? headingAfter
      blockQuoteBefore =
        try values.decodeIfPresent(Double.self, forKey: .blockQuoteBefore) ?? blockQuoteBefore
      blockQuoteAfter =
        try values.decodeIfPresent(Double.self, forKey: .blockQuoteAfter) ?? blockQuoteAfter
      codeBlockBefore =
        try values.decodeIfPresent(Double.self, forKey: .codeBlockBefore) ?? codeBlockBefore
      codeBlockAfter =
        try values.decodeIfPresent(Double.self, forKey: .codeBlockAfter) ?? codeBlockAfter
      detailsBefore =
        try values.decodeIfPresent(Double.self, forKey: .detailsBefore) ?? detailsBefore
      detailsAfter = try values.decodeIfPresent(Double.self, forKey: .detailsAfter) ?? detailsAfter
      listBefore = try values.decodeIfPresent(Double.self, forKey: .listBefore) ?? listBefore
      listAfter = try values.decodeIfPresent(Double.self, forKey: .listAfter) ?? listAfter
      tableBefore = try values.decodeIfPresent(Double.self, forKey: .tableBefore) ?? tableBefore
      tableAfter = try values.decodeIfPresent(Double.self, forKey: .tableAfter) ?? tableAfter
      thematicBreakBefore =
        try values.decodeIfPresent(Double.self, forKey: .thematicBreakBefore) ?? thematicBreakBefore
      thematicBreakAfter =
        try values.decodeIfPresent(Double.self, forKey: .thematicBreakAfter) ?? thematicBreakAfter
      nestedBlock = try values.decodeIfPresent(Double.self, forKey: .nestedBlock) ?? nestedBlock
      detailsContentIndent =
        try values.decodeIfPresent(Double.self, forKey: .detailsContentIndent)
        ?? detailsContentIndent
      detailsMaxHeight =
        try values.decodeIfPresent(Double.self, forKey: .detailsMaxHeight) ?? detailsMaxHeight
      listItem = try values.decodeIfPresent(Double.self, forKey: .listItem) ?? listItem
      listItemContent =
        try values.decodeIfPresent(Double.self, forKey: .listItemContent) ?? listItemContent
      listMarkerGap =
        try values.decodeIfPresent(Double.self, forKey: .listMarkerGap) ?? listMarkerGap
      listSymbolWidth =
        try values.decodeIfPresent(Double.self, forKey: .listSymbolWidth) ?? listSymbolWidth
      listMarkerWidth =
        try values.decodeIfPresent(Double.self, forKey: .listMarkerWidth) ?? listMarkerWidth
      quoteContentGap =
        try values.decodeIfPresent(Double.self, forKey: .quoteContentGap) ?? quoteContentGap
      alertBottomMargin =
        try values.decodeIfPresent(Double.self, forKey: .alertBottomMargin) ?? alertBottomMargin
      tableColumn = try values.decodeIfPresent(Double.self, forKey: .tableColumn) ?? tableColumn
      tableRow = try values.decodeIfPresent(Double.self, forKey: .tableRow) ?? tableRow
    }
  }
}
