import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

func openAnythingShouldRelinquishPanelKey(
  after reason: OpenAnythingPaletteModel.DismissReason
) -> Bool {
  switch reason {
  case .userCanceled, .hitExecuted:
    return true
  case .windowResignedKey, .scenePhaseBackground:
    return false
  }
}

func openAnythingShouldRestorePresentationTarget(
  after reason: OpenAnythingPaletteModel.DismissReason
) -> Bool {
  switch reason {
  case .userCanceled, .hitExecuted:
    return true
  case .windowResignedKey, .scenePhaseBackground:
    return false
  }
}

func openAnythingCanRestorePresentationTarget(
  isVisible: Bool,
  isMiniaturized: Bool,
  isOnActiveSpace: Bool
) -> Bool {
  isVisible && !isMiniaturized && isOnActiveSpace
}

/// Frame-anchored wrapper around `OpenAnythingPaletteView`. NSHostingView
/// sizes itself to the panel's content rect, and the SwiftUI body uses
/// `.ignoresSafeArea()` so the glass card paints edge-to-edge inside the
/// transparent panel.
struct OpenAnythingPaletteContent: View {
  let model: OpenAnythingPaletteModel
  let execute: (OpenAnythingHit) -> Void
  let onDismiss: () -> Void
  let onContentSizeChange: (CGSize) -> Void
  let beginKeepingPanelOpenActivation: () -> Void
  let endKeepingPanelOpenActivation: () -> Void
  let reviewPinToggle: ((String) -> Void)?
  // The palette renders in a detached NSHostingView, so it inherits none of the
  // scene appearance environment. Mirror the app text-size scale here so palette
  // text honors the font-size setting and updates live when it changes.
  @AppStorage(HarnessMonitorTextSize.storageKey)
  private var textSizeIndex = HarnessMonitorTextSize.defaultIndex
  // Palette-only transparency switch. Injected into the glass environment below
  // so the floating card honors the Settings toggle while every other glass
  // surface in the app keeps its default translucency.
  @AppStorage(OpenAnythingPreferencesDefaults.transparencyEnabledKey)
  private var transparencyEnabled = OpenAnythingPreferencesDefaults.transparencyEnabledDefault

  var body: some View {
    let normalizedTextSizeIndex = HarnessMonitorTextSize.normalizedIndex(textSizeIndex)
    OpenAnythingPaletteView(
      model: model,
      execute: execute,
      onDismiss: onDismiss,
      onContentSizeChange: onContentSizeChange,
      beginKeepingPanelOpenActivation: beginKeepingPanelOpenActivation,
      endKeepingPanelOpenActivation: endKeepingPanelOpenActivation,
      reviewPinToggle: reviewPinToggle
    )
    .environment(\.harnessTextSizeIndex, normalizedTextSizeIndex)
    .environment(\.harnessFloatingGlassTransparencyEnabled, transparencyEnabled)
    .sessionFontScale(textSizeIndex: normalizedTextSizeIndex)
    .ignoresSafeArea()
  }
}
