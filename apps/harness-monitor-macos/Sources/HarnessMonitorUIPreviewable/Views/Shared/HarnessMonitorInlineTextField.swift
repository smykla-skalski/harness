import SwiftUI

/// Shared painted text field for dense panels that need inline chrome.
struct HarnessMonitorInlineTextField: View {
  let title: String
  @Binding var text: String
  let prompt: String
  let hasVisibleLabel: Bool
  let accessibilityIdentifier: String?
  let fieldAlignment: Alignment
  let textAlignment: TextAlignment
  let showsClearButton: Bool
  @FocusState private var isFocused: Bool

  init(
    title: String,
    text: Binding<String>,
    prompt: String,
    hasVisibleLabel: Bool = false,
    accessibilityIdentifier: String? = nil,
    fieldAlignment: Alignment = .leading,
    textAlignment: TextAlignment = .leading,
    showsClearButton: Bool = true
  ) {
    self.title = title
    _text = text
    self.prompt = hasVisibleLabel && prompt == title ? "" : prompt
    self.hasVisibleLabel = hasVisibleLabel
    self.accessibilityIdentifier = accessibilityIdentifier
    self.fieldAlignment = fieldAlignment
    self.textAlignment = textAlignment
    self.showsClearButton = showsClearButton
  }

  var body: some View {
    HStack(alignment: .center, spacing: 7) {
      TextField("", text: $text, prompt: Text(prompt))
        .textFieldStyle(.plain)
        .harnessNativeFormControl()
        .multilineTextAlignment(textAlignment)
        .focused($isFocused)
        .accessibilityLabel(title)
        .accessibilityIdentifier(accessibilityIdentifier ?? "")
        .frame(minWidth: 0, maxWidth: .infinity, alignment: fieldAlignment)
        .layoutPriority(1)

      if showsClearButton && !text.isEmpty {
        Button {
          text = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .imageScale(.small)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Clear \(title)")
      }
    }
    .frame(minWidth: 0, maxWidth: .infinity, alignment: fieldAlignment)
    .modifier(HarnessMonitorInlineFieldChromeModifier(isFocused: isFocused))
    .contentShape(Rectangle())
    .onTapGesture {
      isFocused = true
    }
  }
}

/// Shared painted multiline editor for dense panels that need inline chrome
/// instead of the default rounded-border field.
struct HarnessMonitorInlineMultilineTextField: View {
  let title: String
  @Binding var text: String
  let prompt: String
  let hasVisibleLabel: Bool
  let accessibilityIdentifier: String?
  let minHeight: CGFloat
  private let maxHeight: CGFloat?

  @Environment(\.harnessTextSizeIndex)
  private var textSizeIndex
  @Environment(\.harnessNativeFormControlSize)
  private var controlSize
  @FocusState private var isFocused: Bool

  init(
    title: String,
    text: Binding<String>,
    prompt: String,
    hasVisibleLabel: Bool = false,
    accessibilityIdentifier: String? = nil,
    minHeight: CGFloat,
    maxHeight: CGFloat? = nil
  ) {
    self.title = title
    _text = text
    self.prompt = hasVisibleLabel && prompt == title ? "" : prompt
    self.hasVisibleLabel = hasVisibleLabel
    self.accessibilityIdentifier = accessibilityIdentifier
    self.minHeight = minHeight
    self.maxHeight = maxHeight.map { max(minHeight, $0) }
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      if text.isEmpty && !prompt.isEmpty {
        Text(prompt)
          .font(HarnessMonitorTextSize.nativeInputFont(at: textSizeIndex))
          .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
          .padding(.horizontal, 5)
          .padding(.vertical, 6)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }

      TextEditor(text: $text)
        .scrollContentBackground(.hidden)
        .font(HarnessMonitorTextSize.nativeInputFont(at: textSizeIndex))
        .controlSize(HarnessMonitorTextSize.nativeInputControlSize(at: textSizeIndex))
        .focused($isFocused)
        .accessibilityLabel(title)
        .accessibilityIdentifier(accessibilityIdentifier ?? "")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .modifier(
      HarnessMonitorInlineFieldChromeModifier(
        isFocused: isFocused,
        usesFixedHeight: false,
        minHeight: minHeight,
        maxHeight: maxHeight,
        verticalPadding: verticalPadding,
        contentAlignment: .topLeading
      )
    )
    .contentShape(Rectangle())
    .onTapGesture {
      isFocused = true
    }
  }

  private var verticalPadding: CGFloat {
    switch controlSize {
    case .mini, .small:
      7
    case .regular, .large, .extraLarge:
      8
    @unknown default:
      8
    }
  }
}

private struct HarnessMonitorInlineFieldChromeModifier: ViewModifier {
  let isFocused: Bool
  let usesFixedHeight: Bool
  let minHeight: CGFloat?
  let maxHeight: CGFloat?
  let verticalPadding: CGFloat
  let contentAlignment: Alignment
  @Environment(\.harnessNativeFormControlSize)
  private var controlSize
  @Environment(\.fontScale)
  private var fontScale
  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast

  init(
    isFocused: Bool,
    usesFixedHeight: Bool = true,
    minHeight: CGFloat? = nil,
    maxHeight: CGFloat? = nil,
    verticalPadding: CGFloat = 0,
    contentAlignment: Alignment = .center
  ) {
    self.isFocused = isFocused
    self.usesFixedHeight = usesFixedHeight
    self.minHeight = minHeight
    self.maxHeight = maxHeight
    self.verticalPadding = verticalPadding
    self.contentAlignment = contentAlignment
  }

  private var controlHeight: CGFloat {
    if usesExpandedZoomMetrics {
      return switch controlSize {
      case .mini, .small, .regular: 24
      case .large, .extraLarge: 28
      @unknown default: 24
      }
    }
    return switch controlSize {
    case .mini: 18
    case .small: 20.5
    case .regular: 24
    case .large: 28
    case .extraLarge: 32
    @unknown default: 24
    }
  }

  private var horizontalPadding: CGFloat {
    switch controlSize {
    case .mini, .small: 10
    case .regular, .large, .extraLarge: 12
    @unknown default: 12
    }
  }

  private var multilineHorizontalPadding: CGFloat {
    verticalPadding
  }

  private var cornerRadius: CGFloat {
    usesCapsuleCorners ? controlHeight / 2 : (usesFixedHeight ? controlHeight * 0.22 : 10)
  }

  private var usesCapsuleCorners: Bool {
    usesFixedHeight && usesExpandedZoomMetrics
  }

  private var usesExpandedZoomMetrics: Bool {
    fontScale >= HarnessMonitorTextSize.scale(at: 6)
      || controlSize == .large
      || controlSize == .extraLarge
  }

  private var fillOpacity: Double {
    colorSchemeContrast == .increased ? 0.18 : 0.13
  }

  private var strokeOpacity: Double {
    colorSchemeContrast == .increased ? 0.46 : 0.30
  }

  private var strokeWidth: CGFloat {
    colorSchemeContrast == .increased ? 1.5 : 1
  }

  private var focusedStrokeWidth: CGFloat {
    colorSchemeContrast == .increased ? 4 : 3
  }

  func body(content: Content) -> some View {
    if usesFixedHeight {
      content
        .padding(.horizontal, horizontalPadding)
        .frame(height: controlHeight, alignment: .center)
        .clipped()
        .background {
          controlFill
        }
        .overlay {
          controlStroke
        }
    } else {
      content
        .padding(.horizontal, multilineHorizontalPadding)
        .padding(.vertical, verticalPadding)
        .frame(
          maxWidth: .infinity,
          minHeight: minHeight ?? controlHeight,
          maxHeight: maxHeight,
          alignment: contentAlignment
        )
        .clipped()
        .background {
          controlFill
        }
        .overlay {
          controlStroke
        }
    }
  }

  @ViewBuilder private var controlFill: some View {
    let fill = HarnessMonitorTheme.ink.opacity(fillOpacity)
    if usesCapsuleCorners {
      Capsule(style: .continuous)
        .fill(fill)
    } else {
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(fill)
    }
  }

  @ViewBuilder private var controlStroke: some View {
    let stroke =
      isFocused
      ? HarnessMonitorTheme.accent.opacity(0.82)
      : HarnessMonitorTheme.controlBorder.opacity(strokeOpacity)
    let lineWidth = isFocused ? focusedStrokeWidth : strokeWidth

    if usesCapsuleCorners {
      Capsule(style: .continuous)
        .strokeBorder(stroke, lineWidth: lineWidth)
    } else {
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .strokeBorder(stroke, lineWidth: lineWidth)
    }
  }
}
