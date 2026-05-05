import HarnessMonitorKit
import SwiftUI

struct SessionTimelineSearchField: View {
  @Binding var query: String
  @FocusState private var isFocused: Bool

  var body: some View {
    HStack(alignment: .center, spacing: 7) {
      Image(systemName: "magnifyingglass")
        .imageScale(.small)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)

      TextField("Search timeline", text: $query)
        .textFieldStyle(.plain)
        .harnessNativeFormControl()
        .focused($isFocused)
        .accessibilityLabel("Search timeline")
        .accessibilityIdentifier(HarnessMonitorAccessibility.sessionTimelineFilterSearch)
        .layoutPriority(1)

      if !query.isEmpty {
        Button {
          query = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .imageScale(.small)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Clear timeline search")
      }
    }
    .modifier(SessionTimelineSearchFieldChromeModifier(isFocused: isFocused))
    .contentShape(Rectangle())
    .onTapGesture {
      isFocused = true
    }
  }
}

enum SessionTimelineFilterControlLayout {
  static let readableHorizontalSearchWidth: CGFloat = 560

  static func horizontalMinimumWidth(fontScale: CGFloat) -> CGFloat {
    readableHorizontalSearchWidth * max(1, min(fontScale, 1.3))
  }
}

private struct SessionTimelineSearchFieldChromeModifier: ViewModifier {
  let isFocused: Bool

  @Environment(\.harnessNativeFormControlSize)
  private var controlSize
  @Environment(\.fontScale)
  private var fontScale
  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast

  private var controlHeight: CGFloat {
    if usesExpandedZoomMetrics {
      switch controlSize {
      case .mini, .small, .regular, .large:
        25
      case .extraLarge:
        29
      @unknown default:
        25
      }
    } else {
      switch controlSize {
      case .mini:
        18
      case .small:
        20.5
      case .regular:
        24
      case .large:
        28
      case .extraLarge:
        32
      @unknown default:
        24
      }
    }
  }

  private var horizontalPadding: CGFloat {
    switch controlSize {
    case .mini, .small:
      10
    case .regular:
      12
    case .large, .extraLarge:
      12
    @unknown default:
      12
    }
  }

  private var cornerRadius: CGFloat {
    if usesCapsuleCorners {
      controlHeight / 2
    } else {
      switch controlSize {
      case .mini:
        7
      case .small, .large, .extraLarge:
        9
      case .regular:
        10
      @unknown default:
        10
      }
    }
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

  @ViewBuilder
  private var controlFill: some View {
    let fill = HarnessMonitorTheme.ink.opacity(fillOpacity)
    if usesCapsuleCorners {
      Capsule(style: .continuous)
        .fill(fill)
    } else {
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(fill)
    }
  }

  @ViewBuilder
  private var controlStroke: some View {
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
