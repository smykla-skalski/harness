import SwiftUI

struct HarnessMonitorMultilineTextField<Field: Hashable>: View {
  @Environment(\.harnessNativeFormControlFont)
  private var font
  let placeholder: String
  @Binding private var text: String
  private let minHeight: CGFloat
  private let lineLimit: ClosedRange<Int>
  private let focusedField: FocusState<Field?>.Binding?
  private let focusValue: Field?
  private let accessibilityLabel: String
  private let accessibilityHint: String

  init(
    placeholder: String,
    text: Binding<String>,
    minHeight: CGFloat,
    lineLimit: ClosedRange<Int>? = nil,
    focusedField: FocusState<Field?>.Binding? = nil,
    equals focusValue: Field? = nil,
    accessibilityLabel: String? = nil,
    accessibilityHint: String = ""
  ) {
    self.placeholder = placeholder
    _text = text
    self.minHeight = minHeight
    self.lineLimit = lineLimit ?? Self.recommendedLineLimit(for: minHeight)
    self.focusedField = focusedField
    self.focusValue = focusValue
    self.accessibilityLabel = accessibilityLabel ?? placeholder
    self.accessibilityHint = accessibilityHint
  }

  var body: some View {
    multilineEditor
  }

  private var multilineEditor: some View {
    ZStack(alignment: .topLeading) {
      if text.isEmpty, !placeholder.isEmpty {
        Text(placeholder)
          .font(font)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .padding(.horizontal, HarnessMonitorTheme.spacingSM)
          .padding(.vertical, HarnessMonitorTheme.spacingXS)
          .allowsHitTesting(false)
      }

      textEditor
    }
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(HarnessMonitorTheme.ink.opacity(0.10))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(HarnessMonitorTheme.controlBorder.opacity(0.7), lineWidth: 1)
    )
    .contentShape(Rectangle())
  }

  @ViewBuilder
  private var textEditor: some View {
    if let focusedField, let focusValue {
      baseTextEditor
        .focused(focusedField, equals: focusValue)
    } else {
      baseTextEditor
    }
  }

  private var baseTextEditor: some View {
    TextEditor(text: $text)
      .font(font)
      .scrollContentBackground(.hidden)
      .frame(
        maxWidth: .infinity,
        minHeight: minHeight,
        maxHeight: maxHeight,
        alignment: .topLeading
      )
      .accessibilityLabel(accessibilityLabel)
      .accessibilityHint(accessibilityHint)
  }

  private var maxHeight: CGFloat {
    let estimatedLineHeight: CGFloat = 22
    let paddingAllowance = HarnessMonitorTheme.spacingLG
    let preferredHeight = CGFloat(lineLimit.upperBound) * estimatedLineHeight + paddingAllowance
    return max(minHeight, preferredHeight)
  }

  private static func recommendedLineLimit(for minHeight: CGFloat) -> ClosedRange<Int> {
    let minimumVisibleLines = max(3, Int((minHeight / 22).rounded(.up)))
    return minimumVisibleLines...(minimumVisibleLines * 2)
  }
}
