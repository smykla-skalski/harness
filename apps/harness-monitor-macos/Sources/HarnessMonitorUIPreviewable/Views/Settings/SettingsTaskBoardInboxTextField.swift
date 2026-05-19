import AppKit
import SwiftUI

struct SettingsTaskBoardInboxTextField: View {
  let placeholder: String
  @Binding var text: String
  let accessibilityIdentifier: String
  let onSubmit: () -> Void

  @Environment(\.fontScale)
  private var fontScale

  @State private var focusRequest = 0

  private var bodyFont: Font {
    HarnessMonitorTextSize.scaledFont(.body, by: fontScale)
  }

  private var appKitFont: NSFont {
    NSFont.systemFont(ofSize: NSFont.systemFontSize * fontScale)
  }

  var body: some View {
    ZStack(alignment: .leading) {
      if text.isEmpty {
        Text(placeholder)
          .font(bodyFont)
          .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
          .allowsHitTesting(false)
      }

      SettingsTaskBoardInboxNativeTextField(
        text: $text,
        font: appKitFont,
        focusRequest: focusRequest,
        onSubmit: onSubmit
      )
      .frame(maxWidth: .infinity, minHeight: 34, alignment: .center)
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingSM)
    .frame(maxWidth: .infinity, minHeight: 34, alignment: .center)
    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .onTapGesture {
      focusRequest &+= 1
    }
    .background {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color(nsColor: .textBackgroundColor).opacity(0.42))
    }
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color(nsColor: .separatorColor).opacity(0.62), lineWidth: 1)
    }
    .accessibilityLabel(placeholder)
    .accessibilityIdentifier(accessibilityIdentifier)
  }
}

private struct SettingsTaskBoardInboxNativeTextField: NSViewRepresentable {
  @Binding var text: String
  let font: NSFont
  let focusRequest: Int
  let onSubmit: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text, onSubmit: onSubmit)
  }

  func makeNSView(context: Context) -> TextFieldHostView {
    let hostView = TextFieldHostView()
    configure(hostView.textField, context: context)
    return hostView
  }

  func updateNSView(_ hostView: TextFieldHostView, context: Context) {
    let textField = hostView.textField
    if textField.stringValue != text {
      textField.stringValue = text
    }
    textField.font = font
    textField.alignment = .left
    context.coordinator.text = $text
    context.coordinator.onSubmit = onSubmit

    guard context.coordinator.focusRequest != focusRequest else {
      return
    }
    context.coordinator.focusRequest = focusRequest
    DispatchQueue.main.async { [weak hostView] in
      hostView?.focusTextField()
    }
  }

  private func configure(_ textField: NSTextField, context: Context) {
    textField.delegate = context.coordinator
    textField.font = font
    textField.alignment = .left
    textField.isEditable = true
    textField.isSelectable = true
    textField.isBordered = false
    textField.isBezeled = false
    textField.drawsBackground = false
    textField.focusRingType = .none
    textField.lineBreakMode = .byTruncatingTail
    textField.maximumNumberOfLines = 1
    textField.cell?.wraps = false
    textField.cell?.isScrollable = true
    textField.cell?.usesSingleLineMode = true
    textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
    textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
  }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    var text: Binding<String>
    var onSubmit: () -> Void
    var focusRequest = 0

    init(text: Binding<String>, onSubmit: @escaping () -> Void) {
      self.text = text
      self.onSubmit = onSubmit
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let textField = notification.object as? NSTextField else {
        return
      }
      text.wrappedValue = textField.stringValue
    }

    func control(
      _ control: NSControl,
      textView _: NSTextView,
      doCommandBy commandSelector: Selector
    ) -> Bool {
      guard commandSelector == #selector(NSResponder.insertNewline(_:)) else {
        return false
      }
      if let textField = control as? NSTextField {
        text.wrappedValue = textField.stringValue
      }
      onSubmit()
      return true
    }
  }

  final class TextFieldHostView: NSView {
    let textField = NSTextField()

    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      setup()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
      nil
    }

    override func mouseDown(with _: NSEvent) {
      focusTextField()
    }

    func focusTextField() {
      window?.makeFirstResponder(textField)
    }

    private func setup() {
      textField.translatesAutoresizingMaskIntoConstraints = false
      addSubview(textField)

      NSLayoutConstraint.activate([
        textField.leadingAnchor.constraint(equalTo: leadingAnchor),
        textField.trailingAnchor.constraint(equalTo: trailingAnchor),
        textField.centerYAnchor.constraint(equalTo: centerYAnchor),
      ])
    }
  }
}
