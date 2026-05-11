import SwiftUI

struct HarnessMonitorMultilineTextField<Field: Hashable>: View {
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

  @ViewBuilder
  var body: some View {
    // Keep multiline create-form inputs in the surrounding scroll view; the old
    // agent-create flow used TextField(axis: .vertical) rather than nested
    // TextEditor scroll views, and we restore that here.
    let field =
      TextField(placeholder, text: $text, axis: .vertical)
      .harnessNativeTextField()
      .lineLimit(lineLimit)
      .frame(minHeight: minHeight, alignment: .topLeading)
      .accessibilityLabel(accessibilityLabel)
      .accessibilityHint(accessibilityHint)

    if let focusedField, let focusValue {
      field
        .focused(focusedField, equals: focusValue)
        .simultaneousGesture(
          TapGesture().onEnded {
            focusedField.wrappedValue = focusValue
          }
        )
    } else {
      field
    }
  }

  private static func recommendedLineLimit(for minHeight: CGFloat) -> ClosedRange<Int> {
    let minimumVisibleLines = max(3, Int((minHeight / 22).rounded(.up)))
    return minimumVisibleLines...(minimumVisibleLines * 2)
  }
}
