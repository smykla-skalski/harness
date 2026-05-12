import SwiftUI

struct HarnessMonitorMultilineTextField<Field: Hashable>: View {
  @Environment(\.harnessTextSizeIndex)
  private var textSizeIndex
  let placeholder: String
  @Binding private var text: String
  private let minHeight: CGFloat
  private let maxHeightOverride: CGFloat?
  private let lineLimit: ClosedRange<Int>
  private let focusedField: FocusState<Field?>.Binding?
  private let focusValue: Field?
  private let accessibilityLabel: String
  private let accessibilityHint: String

  init(
    placeholder: String,
    text: Binding<String>,
    minHeight: CGFloat,
    maxHeight: CGFloat? = nil,
    lineLimit: ClosedRange<Int>? = nil,
    focusedField: FocusState<Field?>.Binding? = nil,
    equals focusValue: Field? = nil,
    accessibilityLabel: String? = nil,
    accessibilityHint: String = ""
  ) {
    self.placeholder = placeholder
    _text = text
    self.minHeight = minHeight
    maxHeightOverride = maxHeight
    self.lineLimit = lineLimit ?? Self.recommendedLineLimit(for: minHeight)
    self.focusedField = focusedField
    self.focusValue = focusValue
    self.accessibilityLabel = accessibilityLabel ?? placeholder
    self.accessibilityHint = accessibilityHint
  }

  var body: some View {
    multilineField
      .accessibilityLabel(accessibilityLabel)
      .accessibilityHint(accessibilityHint)
  }

  @ViewBuilder
  private var multilineField: some View {
    if let focusedField, let focusValue {
      baseField
        .focused(focusedField, equals: focusValue)
    } else {
      baseField
    }
  }

  private var baseField: some View {
    TextField(placeholder, text: $text, axis: .vertical)
      .multilineTextAlignment(.leading)
      .font(HarnessMonitorTextSize.nativeInputFont(at: textSizeIndex))
      .controlSize(HarnessMonitorTextSize.nativeInputControlSize(at: textSizeIndex))
      .textFieldStyle(.roundedBorder)
      .lineLimit(lineLimit)
      .frame(
        maxWidth: .infinity,
        minHeight: minHeight,
        maxHeight: maxHeight,
        alignment: .topLeading
      )
  }

  private var maxHeight: CGFloat {
    if let maxHeightOverride {
      return maxHeightOverride
    }
    let estimatedLineHeight: CGFloat = 22
    let preferredHeight = CGFloat(lineLimit.upperBound) * estimatedLineHeight
    return max(minHeight, preferredHeight)
  }

  private static func recommendedLineLimit(for minHeight: CGFloat) -> ClosedRange<Int> {
    let minimumVisibleLines = max(3, Int((minHeight / 22).rounded(.up)))
    return minimumVisibleLines...(minimumVisibleLines * 2)
  }
}
