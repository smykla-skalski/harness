import SwiftUI

struct TaskBoardOperationsTextField: View {
  let title: String
  @Binding var text: String
  let prompt: String
  let accessibilityIdentifier: String? = nil
  let fieldAlignment: Alignment = .trailing
  let textAlignment: TextAlignment = .trailing
  let showsClearButton: Bool = true
  @FocusState private var isFocused: Bool

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
    .modifier(TaskBoardOperationsTextFieldChrome(isFocused: isFocused))
    .contentShape(Rectangle())
    .onTapGesture {
      isFocused = true
    }
  }
}

struct TaskBoardOperationsMultilineTextField: View {
  let title: String
  @Binding var text: String
  let prompt: String
  let accessibilityIdentifier: String?
  let minHeight: CGFloat
  private let maxHeightOverride: CGFloat?
  private let lineLimit: ClosedRange<Int>

  @Environment(\.harnessTextSizeIndex)
  private var textSizeIndex
  @Environment(\.harnessNativeFormControlSize)
  private var controlSize
  @FocusState private var isFocused: Bool

  init(
    title: String,
    text: Binding<String>,
    prompt: String,
    accessibilityIdentifier: String? = nil,
    minHeight: CGFloat,
    maxHeight: CGFloat? = nil,
    lineLimit: ClosedRange<Int>? = nil
  ) {
    self.title = title
    _text = text
    self.prompt = prompt
    self.accessibilityIdentifier = accessibilityIdentifier
    self.minHeight = minHeight
    maxHeightOverride = maxHeight
    self.lineLimit = lineLimit ?? Self.recommendedLineLimit(for: minHeight)
  }

  var body: some View {
    TextField("", text: $text, prompt: Text(prompt), axis: .vertical)
      .textFieldStyle(.plain)
      .multilineTextAlignment(.leading)
      .font(HarnessMonitorTextSize.nativeInputFont(at: textSizeIndex))
      .controlSize(HarnessMonitorTextSize.nativeInputControlSize(at: textSizeIndex))
      .lineLimit(lineLimit)
      .focused($isFocused)
      .accessibilityLabel(title)
      .accessibilityIdentifier(accessibilityIdentifier ?? "")
      .modifier(
        TaskBoardOperationsTextFieldChrome(
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

  private var maxHeight: CGFloat {
    if let maxHeightOverride {
      return maxHeightOverride
    }
    let estimatedLineHeight: CGFloat = 22
    let preferredHeight = CGFloat(lineLimit.upperBound) * estimatedLineHeight
    return max(minHeight, preferredHeight)
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

  private static func recommendedLineLimit(for minHeight: CGFloat) -> ClosedRange<Int> {
    let minimumVisibleLines = max(3, Int((minHeight / 22).rounded(.up)))
    return minimumVisibleLines...(minimumVisibleLines * 2)
  }
}

private struct TaskBoardOperationsTextFieldChrome: ViewModifier {
  let isFocused: Bool
  let usesFixedHeight: Bool = true
  let minHeight: CGFloat? = nil
  let maxHeight: CGFloat? = nil
  let verticalPadding: CGFloat = 0
  let contentAlignment: Alignment = .center
  @Environment(\.harnessNativeFormControlSize)
  private var controlSize
  @Environment(\.fontScale)
  private var fontScale
  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast

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
    colorSchemeContrast == .increased ? 2 : 1.5
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
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .frame(
          maxWidth: .infinity,
          minHeight: minHeight ?? controlHeight,
          maxHeight: maxHeight,
          alignment: contentAlignment
        )
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
