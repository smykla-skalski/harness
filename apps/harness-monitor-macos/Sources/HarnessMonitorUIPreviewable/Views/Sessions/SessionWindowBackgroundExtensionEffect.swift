import SwiftUI

private struct HarnessMonitorBackgroundExtensionEffectModifier: ViewModifier {
  let respectsBackdropMode: Bool

  @AppStorage(HarnessMonitorBackdropDefaults.modeKey)
  private var backdropModeRawValue = HarnessMonitorBackdropMode.none.rawValue
  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency

  private var backdropMode: HarnessMonitorBackdropMode {
    HarnessMonitorBackdropMode(rawValue: backdropModeRawValue) ?? .none
  }

  func body(content: Content) -> some View {
    if reduceTransparency || (respectsBackdropMode && backdropMode == .none) {
      content
    } else {
      content.backgroundExtensionEffect()
    }
  }
}

extension View {
  @ViewBuilder
  func harnessMonitorBackgroundExtensionEffect() -> some View {
    if HarnessMonitorUITestEnvironment.disablesVisualOptions {
      self
    } else {
      modifier(HarnessMonitorBackgroundExtensionEffectModifier(respectsBackdropMode: true))
    }
  }

  @ViewBuilder
  func harnessMonitorToolbarBackgroundExtensionEffect() -> some View {
    if HarnessMonitorUITestEnvironment.disablesVisualOptions {
      self
    } else {
      modifier(HarnessMonitorBackgroundExtensionEffectModifier(respectsBackdropMode: false))
    }
  }

  @ViewBuilder
  func sessionWindowBackgroundExtensionEffect() -> some View {
    harnessMonitorToolbarBackgroundExtensionEffect()
  }
}
