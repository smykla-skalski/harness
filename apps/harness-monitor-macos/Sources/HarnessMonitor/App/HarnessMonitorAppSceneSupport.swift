import HarnessMonitorKit
import HarnessMonitorUI
import SwiftUI

struct HarnessMonitorWindowRootView: View {
  let delegate: HarnessMonitorAppDelegate
  let store: HarnessMonitorStore
  @Binding var themeMode: HarnessMonitorThemeMode

  var body: some View {
    ContentView(store: store)
      .frame(minWidth: 900, minHeight: 600)
      .instantFocusRing()
      .modifier(HarnessMonitorSceneAppearanceModifier(themeMode: $themeMode))
      .modifier(HarnessMonitorUITestAnimationModifier())
      .task {
        delegate.bind(store: store)
        await store.bootstrapIfNeeded()
      }
  }
}

struct HarnessMonitorSettingsRootView: View {
  let store: HarnessMonitorStore
  @Binding var themeMode: HarnessMonitorThemeMode

  var body: some View {
    PreferencesView(
      store: store,
      themeMode: $themeMode
    )
    .frame(minWidth: 680, minHeight: 440)
    .instantFocusRing()
    .modifier(HarnessMonitorSceneAppearanceModifier(themeMode: $themeMode))
    .modifier(HarnessMonitorUITestAnimationModifier())
  }
}

private struct HarnessMonitorUITestAnimationModifier: ViewModifier {
  private static let isUITesting =
    ProcessInfo.processInfo.environment["HARNESS_MONITOR_UI_TESTS"] == "1"

  func body(content: Content) -> some View {
    if Self.isUITesting {
      content.transaction { $0.disablesAnimations = true }
    } else {
      content
    }
  }
}

private struct HarnessMonitorSceneAppearanceModifier: ViewModifier {
  @Binding var themeMode: HarnessMonitorThemeMode
  @AppStorage(HarnessMonitorThemeDefaults.modeKey)
  private var storedThemeMode = HarnessMonitorThemeMode.auto.rawValue
  @AppStorage(HarnessMonitorTextSize.storageKey)
  private var textSizeIndex = HarnessMonitorTextSize.defaultIndex
  @AppStorage(HarnessMonitorDateTimeConfiguration.timeZoneModeKey)
  private var timeZoneModeRawValue = HarnessMonitorDateTimeConfiguration.defaultTimeZoneModeRawValue
  @AppStorage(HarnessMonitorDateTimeConfiguration.customTimeZoneIdentifierKey)
  private var customTimeZoneIdentifier = HarnessMonitorDateTimeConfiguration.defaultCustomTimeZoneIdentifier

  private var dateTimeConfiguration: HarnessMonitorDateTimeConfiguration {
    HarnessMonitorDateTimeConfiguration(
      timeZoneModeRawValue: timeZoneModeRawValue,
      customTimeZoneIdentifier: customTimeZoneIdentifier
    )
  }

  func body(content: Content) -> some View {
    let normalizedTextSizeIndex = HarnessMonitorTextSize.normalizedIndex(textSizeIndex)

    content
      .environment(\.harnessTextSizeIndex, normalizedTextSizeIndex)
      .environment(\.fontScale, HarnessMonitorTextSize.scale(at: normalizedTextSizeIndex))
      .environment(
        \.harnessNativeFormControlFont,
        HarnessMonitorTextSize.nativeFormControlFont(at: normalizedTextSizeIndex)
      )
      .environment(
        \.harnessNativeFormControlSize,
        HarnessMonitorTextSize.controlSize(at: normalizedTextSizeIndex)
      )
      .environment(\.harnessDateTimeConfiguration, dateTimeConfiguration)
      .preferredColorScheme(themeMode.colorScheme)
      .tint(HarnessMonitorTheme.accent)
      .onAppear(perform: syncThemeFromStorage)
      .onChange(of: storedThemeMode) { _, _ in syncThemeFromStorage() }
      .onChange(of: themeMode) { _, new in storedThemeMode = new.rawValue }
  }

  private func syncThemeFromStorage() {
    themeMode = HarnessMonitorThemeMode(rawValue: storedThemeMode) ?? .auto
  }
}
