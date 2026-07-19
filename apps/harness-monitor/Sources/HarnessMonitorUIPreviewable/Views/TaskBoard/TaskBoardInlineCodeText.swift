import Foundation
import SwiftUI

/// Internal (not private) and `Sendable` so the presentation worker can scan once, off the main
/// actor, and hand fragments to leaf views instead of every render re-running the scanner.
struct TaskBoardInlineCodeFragment: Equatable, Sendable {
  let text: String
  let isCode: Bool
}

enum TaskBoardInlineCodeFormatter {
  static func displayText(for rawText: String, leadingText: String? = nil) -> String {
    displayText(for: fragments(in: rawText), leadingText: leadingText)
  }

  static func displayText(
    for fragments: [TaskBoardInlineCodeFragment],
    leadingText: String? = nil
  ) -> String {
    (leadingText ?? "") + fragments.map(\.text).joined()
  }

  static func attributedText(
    for rawText: String,
    codeFont: Font,
    leadingText: String? = nil,
    leadingForeground: Color = HarnessMonitorTheme.tertiaryInk,
    codeForeground: Color = HarnessMonitorTheme.inlineCodeText,
    codeBackground: Color = HarnessMonitorTheme.inlineCodeBackground
  ) -> AttributedString {
    attributedText(
      for: fragments(in: rawText),
      codeFont: codeFont,
      leadingText: leadingText,
      leadingForeground: leadingForeground,
      codeForeground: codeForeground,
      codeBackground: codeBackground
    )
  }

  static func attributedText(
    for fragments: [TaskBoardInlineCodeFragment],
    codeFont: Font,
    leadingText: String? = nil,
    leadingForeground: Color = HarnessMonitorTheme.tertiaryInk,
    codeForeground: Color = HarnessMonitorTheme.inlineCodeText,
    codeBackground: Color = HarnessMonitorTheme.inlineCodeBackground
  ) -> AttributedString {
    var result = AttributedString()
    if let leadingText, leadingText.isEmpty == false {
      var attributedLeadingText = AttributedString(leadingText)
      attributedLeadingText.foregroundColor = leadingForeground
      result += attributedLeadingText
    }
    return fragments.reduce(into: result) { result, fragment in
      var attributedFragment = AttributedString(fragment.text)
      if fragment.isCode {
        attributedFragment.font = codeFont
        attributedFragment.foregroundColor = codeForeground
        attributedFragment.backgroundColor = codeBackground
      }
      result += attributedFragment
    }
  }

  static func fragments(in rawText: String) -> [TaskBoardInlineCodeFragment] {
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
///
/// Prefer the `fragments:displayText:` init when the caller already has worker-precomputed
/// fragments, so the scanner never re-runs on the render path. The raw-text init stays for callers
/// outside the per-card presentation pipeline (e.g. the step-rail prompt preview).
struct TaskBoardInlineCodeText: View {
  private let fragments: [TaskBoardInlineCodeFragment]
  private let displayText: String
  let font: Font
  let codeFont: Font
  var leadingText: String?
  var leadingForeground: Color = HarnessMonitorTheme.tertiaryInk
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
    leadingText: String? = nil,
    leadingForeground: Color = HarnessMonitorTheme.tertiaryInk,
    foregroundStyle: Color = .primary,
    codeForeground: Color = HarnessMonitorTheme.inlineCodeText,
    codeBackground: Color = HarnessMonitorTheme.inlineCodeBackground,
    lineLimit: Int? = nil,
    truncationMode: Text.TruncationMode = .tail,
    multilineTextAlignment: TextAlignment = .leading
  ) {
    let fragments = TaskBoardInlineCodeFormatter.fragments(in: text)
    self.init(
      fragments: fragments,
      displayText: TaskBoardInlineCodeFormatter.displayText(
        for: fragments,
        leadingText: leadingText
      ),
      font: font,
      codeFont: codeFont,
      leadingText: leadingText,
      leadingForeground: leadingForeground,
      foregroundStyle: foregroundStyle,
      codeForeground: codeForeground,
      codeBackground: codeBackground,
      lineLimit: lineLimit,
      truncationMode: truncationMode,
      multilineTextAlignment: multilineTextAlignment
    )
  }

  init(
    fragments: [TaskBoardInlineCodeFragment],
    displayText: String,
    font: Font,
    codeFont: Font,
    leadingText: String? = nil,
    leadingForeground: Color = HarnessMonitorTheme.tertiaryInk,
    foregroundStyle: Color = .primary,
    codeForeground: Color = HarnessMonitorTheme.inlineCodeText,
    codeBackground: Color = HarnessMonitorTheme.inlineCodeBackground,
    lineLimit: Int? = nil,
    truncationMode: Text.TruncationMode = .tail,
    multilineTextAlignment: TextAlignment = .leading
  ) {
    self.fragments = fragments
    self.displayText = displayText
    self.font = font
    self.codeFont = codeFont
    self.leadingText = leadingText
    self.leadingForeground = leadingForeground
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
        for: fragments,
        codeFont: codeFont,
        leadingText: leadingText,
        leadingForeground: leadingForeground,
        codeForeground: codeForeground,
        codeBackground: codeBackground
      )
    )
    .font(font)
    .foregroundStyle(foregroundStyle)
    .lineLimit(lineLimit)
    .truncationMode(truncationMode)
    .multilineTextAlignment(multilineTextAlignment)
    .accessibilityLabel(displayText)
  }
}
