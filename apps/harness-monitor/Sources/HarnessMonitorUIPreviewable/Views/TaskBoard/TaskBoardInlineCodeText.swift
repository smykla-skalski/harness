import Foundation
import SwiftUI

private struct TaskBoardInlineCodeFragment: Equatable {
  let text: String
  let isCode: Bool
}

enum TaskBoardInlineCodeFormatter {
  static func displayText(for rawText: String) -> String {
    fragments(in: rawText).map(\.text).joined()
  }

  static func attributedText(
    for rawText: String,
    codeFont: Font,
    codeForeground: Color = HarnessMonitorTheme.inlineCodeText,
    codeBackground: Color = HarnessMonitorTheme.inlineCodeBackground
  ) -> AttributedString {
    fragments(in: rawText).reduce(into: AttributedString()) { result, fragment in
      var attributedFragment = AttributedString(fragment.text)
      if fragment.isCode {
        attributedFragment.font = codeFont
        attributedFragment.foregroundColor = codeForeground
        attributedFragment.backgroundColor = codeBackground
      }
      result += attributedFragment
    }
  }

  private static func fragments(in rawText: String) -> [TaskBoardInlineCodeFragment] {
    guard rawText.contains("`") else {
      return [.init(text: rawText, isCode: false)]
    }

    var fragments: [TaskBoardInlineCodeFragment] = []
    var cursor = rawText.startIndex
    var index = rawText.startIndex

    while index < rawText.endIndex {
      guard rawText[index] == "`" else {
        index = rawText.index(after: index)
        continue
      }

      let afterOpen = rawText.index(after: index)
      guard
        let close = rawText[afterOpen...].firstIndex(of: "`"),
        close > afterOpen
      else {
        index = afterOpen
        continue
      }

      if cursor < index {
        fragments.append(.init(text: String(rawText[cursor..<index]), isCode: false))
      }
      fragments.append(.init(text: String(rawText[afterOpen..<close]), isCode: true))
      cursor = rawText.index(after: close)
      index = cursor
    }

    if cursor < rawText.endIndex {
      fragments.append(.init(text: String(rawText[cursor...]), isCode: false))
    }

    return fragments.isEmpty ? [.init(text: rawText, isCode: false)] : fragments
  }
}

/// Lightweight backtick-span renderer that consumes fonts scaled by its container.
struct TaskBoardInlineCodeText: View {
  let text: String
  let font: Font
  let codeFont: Font
  var foregroundStyle: Color = .primary
  var codeForeground: Color = HarnessMonitorTheme.inlineCodeText
  var codeBackground: Color = HarnessMonitorTheme.inlineCodeBackground
  var lineLimit: Int?
  var truncationMode: Text.TruncationMode = .tail
  var multilineTextAlignment: TextAlignment = .leading

  init(
    _ text: String,
    font: Font,
    codeFont: Font,
    foregroundStyle: Color = .primary,
    codeForeground: Color = HarnessMonitorTheme.inlineCodeText,
    codeBackground: Color = HarnessMonitorTheme.inlineCodeBackground,
    lineLimit: Int? = nil,
    truncationMode: Text.TruncationMode = .tail,
    multilineTextAlignment: TextAlignment = .leading
  ) {
    self.text = text
    self.font = font
    self.codeFont = codeFont
    self.foregroundStyle = foregroundStyle
    self.codeForeground = codeForeground
    self.codeBackground = codeBackground
    self.lineLimit = lineLimit
    self.truncationMode = truncationMode
    self.multilineTextAlignment = multilineTextAlignment
  }

  var body: some View {
    Text(
      TaskBoardInlineCodeFormatter.attributedText(
        for: text,
        codeFont: codeFont,
        codeForeground: codeForeground,
        codeBackground: codeBackground
      )
    )
    .font(font)
    .foregroundStyle(foregroundStyle)
    .lineLimit(lineLimit)
    .truncationMode(truncationMode)
    .multilineTextAlignment(multilineTextAlignment)
    .accessibilityLabel(TaskBoardInlineCodeFormatter.displayText(for: text))
  }
}
