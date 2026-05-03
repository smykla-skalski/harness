import HarnessMonitorKit
import SwiftUI

extension WorkspaceWindowCreatePane {
  func multilineEditor(
    placeholder: String,
    text: Binding<String>,
    field: Field,
    minHeight: CGFloat,
    accessibilityIdentifier: String,
    accessibilityLabel: String? = nil,
    accessibilityHint: String? = nil
  ) -> some View {
    // Keep the create-pane form as a single scroll surface. Nested TextEditor
    // scroll views made wheel and trackpad scrolling feel jumpy in the outer pane.
    TextField(placeholder, text: text, axis: .vertical)
      .scaledFont(.body)
      .harnessNativeFormControl()
      .lineLimit(multilineEditorLineLimit(for: minHeight))
      .frame(minHeight: minHeight, alignment: .topLeading)
      .focused(focusedFieldBinding, equals: field)
      .accessibilityFrameMarker(accessibilityIdentifier)
      .accessibilityLabel(accessibilityLabel ?? placeholder)
      .accessibilityHint(accessibilityHint ?? "")
      .harnessMCPTextField(
        accessibilityIdentifier,
        label: accessibilityLabel ?? placeholder,
        value: text.wrappedValue,
        hint: accessibilityHint ?? ""
      )
      .harnessPreservePrimaryContentFocus()
  }

  private func multilineEditorLineLimit(for minHeight: CGFloat) -> ClosedRange<Int> {
    let minimumVisibleLines = max(3, Int((minHeight / 22).rounded(.up)))
    return minimumVisibleLines...(minimumVisibleLines * 2)
  }
}
