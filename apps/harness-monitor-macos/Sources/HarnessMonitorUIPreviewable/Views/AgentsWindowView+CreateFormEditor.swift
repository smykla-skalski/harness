import SwiftUI

extension AgentsWindowCreatePane {
  func multilineEditor(
    placeholder: String,
    text: Binding<String>,
    field: Field,
    minHeight: CGFloat,
    accessibilityIdentifier: String,
    accessibilityLabel: String? = nil,
    accessibilityHint: String? = nil
  ) -> some View {
    ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor))

      if text.wrappedValue.isEmpty {
        Text(placeholder)
          .scaledFont(.body)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .padding(.horizontal, HarnessMonitorTheme.spacingMD)
          .padding(.vertical, HarnessMonitorTheme.spacingSM)
          .allowsHitTesting(false)
      }

      TextEditor(text: text)
        .scaledFont(.body)
        .scrollContentBackground(.hidden)
        .padding(.horizontal, HarnessMonitorTheme.spacingSM)
        .padding(.vertical, HarnessMonitorTheme.spacingXS)
        .focused(focusedFieldBinding, equals: field)
        .accessibilityLabel(accessibilityLabel ?? placeholder)
        .accessibilityHint(accessibilityHint ?? "")
        .accessibilityIdentifier(accessibilityIdentifier)
    }
    .frame(minHeight: minHeight)
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
    }
    .accessibilityFrameMarker(accessibilityIdentifier)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(accessibilityLabel ?? placeholder)
    .accessibilityHint(accessibilityHint ?? "")
    .accessibilityIdentifier(accessibilityIdentifier)
  }
}
