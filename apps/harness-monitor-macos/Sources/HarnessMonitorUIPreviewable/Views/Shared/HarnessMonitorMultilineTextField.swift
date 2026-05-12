import AppKit
import SwiftUI

struct HarnessMonitorMultilineTextField<Field: Hashable>: View {
  @Environment(\.harnessTextSizeIndex)
  private var textSizeIndex
  let placeholder: String
  @Binding private var text: String
  private let minHeight: CGFloat
  private let maxHeightOverride: CGFloat?
  private let lineLimit: ClosedRange<Int>
  private let showsChrome: Bool
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
    showsChrome: Bool = true,
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
    self.showsChrome = showsChrome
    self.focusedField = focusedField
    self.focusValue = focusValue
    self.accessibilityLabel = accessibilityLabel ?? placeholder
    self.accessibilityHint = accessibilityHint
  }

  var body: some View {
    multilineEditor
      .frame(maxWidth: .infinity, alignment: .leading)
      .modifier(HarnessMonitorMultilineChromeModifier(showsChrome: showsChrome))
  }

  private var multilineEditor: some View {
    ZStack(alignment: .topLeading) {
      if text.isEmpty, !placeholder.isEmpty {
        Text(placeholder)
          .font(HarnessMonitorTextSize.nativeInputFont(at: textSizeIndex))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .padding(.horizontal, HarnessMonitorNativeTextFieldChromeMetrics.horizontalPadding)
          .padding(.vertical, HarnessMonitorNativeTextFieldChromeMetrics.verticalPadding)
          .allowsHitTesting(false)
      }

      HarnessMonitorAppKitMultilineTextEditor(
        text: $text,
        textSizeIndex: textSizeIndex,
        isFocused: isFocusedBinding
      )
      .frame(
        maxWidth: .infinity,
        minHeight: minHeight,
        maxHeight: maxHeight,
        alignment: .topLeading
      )
      .accessibilityLabel(accessibilityLabel)
      .accessibilityHint(accessibilityHint)
    }
    .contentShape(Rectangle())
  }

  private var isFocusedBinding: Binding<Bool>? {
    guard let focusedField, let focusValue else { return nil }
    return Binding(
      get: { focusedField.wrappedValue == focusValue },
      set: { isFocused in
        if isFocused {
          focusedField.wrappedValue = focusValue
        }
      }
    )
  }

  private var maxHeight: CGFloat {
    if let maxHeightOverride {
      return maxHeightOverride
    }
    let estimatedLineHeight: CGFloat = 22
    let paddingAllowance = HarnessMonitorNativeTextFieldChromeMetrics.verticalPadding * 2
    let preferredHeight = CGFloat(lineLimit.upperBound) * estimatedLineHeight + paddingAllowance
    return max(minHeight, preferredHeight)
  }

  private static func recommendedLineLimit(for minHeight: CGFloat) -> ClosedRange<Int> {
    let minimumVisibleLines = max(3, Int((minHeight / 22).rounded(.up)))
    return minimumVisibleLines...(minimumVisibleLines * 2)
  }
}

private struct HarnessMonitorMultilineChromeModifier: ViewModifier {
  let showsChrome: Bool

  func body(content: Content) -> some View {
    if showsChrome {
      content
        .background(
          RoundedRectangle(
            cornerRadius: HarnessMonitorNativeTextFieldChromeMetrics.cornerRadius,
            style: .continuous
          )
          .fill(HarnessMonitorTheme.ink.opacity(0.10))
        )
        .overlay(
          RoundedRectangle(
            cornerRadius: HarnessMonitorNativeTextFieldChromeMetrics.cornerRadius,
            style: .continuous
          )
          .stroke(HarnessMonitorTheme.controlBorder.opacity(0.7), lineWidth: 1)
        )
    } else {
      content
    }
  }
}

private struct HarnessMonitorAppKitMultilineTextEditor: NSViewRepresentable {
  @Binding var text: String
  let textSizeIndex: Int
  let isFocused: Binding<Bool>?

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text, isFocused: isFocused)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false
    scrollView.hasHorizontalScroller = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true

    let textView = NSTextView()
    textView.delegate = context.coordinator
    configure(textView)
    textView.string = text
    applyTextAttributes(to: textView)

    scrollView.documentView = textView
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? NSTextView else { return }

    context.coordinator.text = $text
    context.coordinator.isFocused = isFocused

    if textView.string != text {
      textView.string = text
    }

    configure(textView)
    applyTextAttributes(to: textView)

    if let isFocused {
      let firstResponder = scrollView.window?.firstResponder as? NSTextView
      if isFocused.wrappedValue, firstResponder !== textView {
        scrollView.window?.makeFirstResponder(textView)
      }
    }
  }

  private func configure(_ textView: NSTextView) {
    textView.drawsBackground = false
    textView.isRichText = false
    textView.importsGraphics = false
    textView.isHorizontallyResizable = false
    textView.isVerticallyResizable = true
    textView.allowsUndo = true
    textView.usesFindBar = true
    textView.textContainerInset = NSSize(
      width: HarnessMonitorNativeTextFieldChromeMetrics.horizontalPadding,
      height: HarnessMonitorNativeTextFieldChromeMetrics.verticalPadding
    )
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(
      width: 0,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.textContainer?.lineFragmentPadding = 0
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.minSize = .zero
    textView.alignment = .left
    textView.baseWritingDirection = .leftToRight
  }

  private func applyTextAttributes(to textView: NSTextView) {
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = .left
    paragraphStyle.baseWritingDirection = .leftToRight

    let attributes: [NSAttributedString.Key: Any] = [
      .font: resolvedFont(),
      .foregroundColor: NSColor.labelColor,
      .paragraphStyle: paragraphStyle,
    ]

    textView.defaultParagraphStyle = paragraphStyle
    textView.typingAttributes = attributes

    let fullRange = NSRange(location: 0, length: textView.string.utf16.count)
    guard fullRange.length > 0 else { return }
    textView.textStorage?.beginEditing()
    textView.textStorage?.setAttributes(attributes, range: fullRange)
    textView.textStorage?.endEditing()
  }

  private func resolvedFont() -> NSFont {
    let controlSize = HarnessMonitorTextSize.nativeInputControlSize(at: textSizeIndex)
    let inputScale = HarnessMonitorTextSize.scale(
      at: HarnessMonitorTextSize.nativeInputIndex(textSizeIndex)
    )
    let nsControlSize: NSControl.ControlSize =
      switch controlSize {
      case .mini:
        .mini
      case .small:
        .small
      case .regular:
        .regular
      case .large:
        .large
      case .extraLarge:
        .large
      @unknown default:
        .regular
      }
    let basePointSize = NSFont.systemFontSize(for: nsControlSize)
    return NSFont.systemFont(ofSize: basePointSize * inputScale)
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var text: Binding<String>
    var isFocused: Binding<Bool>?

    init(text: Binding<String>, isFocused: Binding<Bool>?) {
      self.text = text
      self.isFocused = isFocused
    }

    func textDidBeginEditing(_ notification: Notification) {
      isFocused?.wrappedValue = true
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      if text.wrappedValue != textView.string {
        text.wrappedValue = textView.string
      }
    }
  }
}
