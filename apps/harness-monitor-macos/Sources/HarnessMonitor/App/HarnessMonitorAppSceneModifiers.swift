import HarnessMonitorUIPreviewable
import SwiftUI

struct PinchToZoomTextSizeModifier: ViewModifier {
  @AppStorage(HarnessMonitorTextSize.storageKey)
  private var textSizeIndex = HarnessMonitorTextSize.defaultIndex

  func body(content: Content) -> some View {
    content.gesture(
      MagnifyGesture(minimumScaleDelta: 0.05)
        .onEnded { value in
          let delta = HarnessMonitorTextSize.indexDelta(
            forMagnification: value.magnification,
            currentIndex: textSizeIndex
          )
          if delta != 0 {
            textSizeIndex += delta
          }
        }
    )
  }
}

struct OptionalPreferredColorSchemeModifier: ViewModifier {
  let colorScheme: ColorScheme?
  let isEnabled: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    if isEnabled {
      content.preferredColorScheme(colorScheme)
    } else {
      content
    }
  }
}
