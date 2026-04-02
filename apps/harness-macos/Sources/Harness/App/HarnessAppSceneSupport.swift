import HarnessKit
import SwiftUI

struct HarnessWindowRootView: View {
  let store: HarnessStore
  @Binding var themeMode: HarnessThemeMode

  var body: some View {
    ContentView(store: store)
      .frame(minWidth: 900, minHeight: 600)
      .modifier(HarnessSceneAppearanceModifier(themeMode: $themeMode))
      .task {
        await store.bootstrapIfNeeded()
      }
  }
}

struct HarnessSettingsRootView: View {
  let store: HarnessStore
  @Binding var themeMode: HarnessThemeMode

  var body: some View {
    PreferencesView(
      store: store,
      themeMode: $themeMode
    )
    .frame(minWidth: 680, minHeight: 440)
    .modifier(HarnessSceneAppearanceModifier(themeMode: $themeMode))
  }
}

private struct HarnessSceneAppearanceModifier: ViewModifier {
  @Binding var themeMode: HarnessThemeMode
  @AppStorage(HarnessThemeDefaults.modeKey)
  private var storedThemeMode = HarnessThemeMode.auto.rawValue
  @AppStorage(HarnessTextSize.storageKey)
  private var textSizeIndex = HarnessTextSize.defaultIndex

  func body(content: Content) -> some View {
    let normalizedTextSizeIndex = HarnessTextSize.normalizedIndex(textSizeIndex)

    content
      .environment(\.harnessTextSizeIndex, normalizedTextSizeIndex)
      .environment(\.fontScale, HarnessTextSize.scale(at: normalizedTextSizeIndex))
      .environment(
        \.harnessNativeFormControlFont,
        HarnessTextSize.nativeFormControlFont(at: normalizedTextSizeIndex)
      )
      .environment(
        \.harnessNativeFormControlSize,
        HarnessTextSize.controlSize(at: normalizedTextSizeIndex)
      )
      .preferredColorScheme(themeMode.colorScheme)
      .tint(HarnessTheme.accent)
      .onAppear(perform: syncThemeFromStorage)
      .onChange(of: storedThemeMode) { _, _ in syncThemeFromStorage() }
      .onChange(of: themeMode) { _, new in storedThemeMode = new.rawValue }
  }

  private func syncThemeFromStorage() {
    themeMode = HarnessThemeMode(rawValue: storedThemeMode) ?? .auto
  }
}
