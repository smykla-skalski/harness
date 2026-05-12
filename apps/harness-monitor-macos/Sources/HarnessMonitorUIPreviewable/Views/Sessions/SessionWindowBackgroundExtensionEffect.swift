import SwiftUI

private struct HarnessMonitorBackgroundExtensionEffectModifier: ViewModifier {
  @AppStorage(HarnessMonitorBackdropDefaults.modeKey)
  private var backdropModeRawValue = HarnessMonitorBackdropMode.none.rawValue
  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency

  private var backdropMode: HarnessMonitorBackdropMode {
    HarnessMonitorBackdropMode(rawValue: backdropModeRawValue) ?? .none
  }

  func body(content: Content) -> some View {
    if reduceTransparency || backdropMode == .none {
      content
    } else {
      content.backgroundExtensionEffect()
    }
  }
}

extension View {
  func harnessMonitorBackgroundExtensionEffect() -> some View {
    modifier(HarnessMonitorBackgroundExtensionEffectModifier())
  }

  func sessionWindowBackgroundExtensionEffect() -> some View {
    harnessMonitorBackgroundExtensionEffect()
  }
}
