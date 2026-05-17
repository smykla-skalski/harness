import SwiftUI

struct TaskBoardOperationsTextField: View {
  let title: String
  @Binding var text: String
  let prompt: String
  let accessibilityIdentifier: String
  @FocusState private var isFocused: Bool

  var body: some View {
    HStack(alignment: .center, spacing: 7) {
      TextField("", text: $text, prompt: Text(prompt))
        .textFieldStyle(.plain)
        .harnessNativeFormControl()
        .multilineTextAlignment(.trailing)
        .focused($isFocused)
        .accessibilityLabel(title)
        .accessibilityIdentifier(accessibilityIdentifier)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
        .layoutPriority(1)

      if !text.isEmpty {
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
    .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
    .modifier(TaskBoardOperationsTextFieldChrome(isFocused: isFocused))
    .contentShape(Rectangle())
    .onTapGesture {
      isFocused = true
    }
  }
}

private struct TaskBoardOperationsTextFieldChrome: ViewModifier {
  let isFocused: Bool
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
    usesCapsuleCorners ? controlHeight / 2 : controlHeight * 0.22
  }

  private var usesCapsuleCorners: Bool {
    usesExpandedZoomMetrics
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
