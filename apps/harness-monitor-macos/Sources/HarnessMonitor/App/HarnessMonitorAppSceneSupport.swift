import HarnessMonitorKit
import HarnessMonitorUI
import SwiftUI

struct HarnessMonitorWindowRootView: View {
  let delegate: HarnessMonitorAppDelegate
  let store: HarnessMonitorStore
  @Binding var themeMode: HarnessMonitorThemeMode
  @AppStorage(HarnessMonitorBackdropDefaults.modeKey)
  private var backdropModeRawValue = HarnessMonitorBackdropMode.none.rawValue
  private let toolbarGlassReproConfiguration = ToolbarGlassReproConfiguration.current

  private var backdropMode: HarnessMonitorBackdropMode {
    HarnessMonitorBackdropMode(rawValue: backdropModeRawValue) ?? .none
  }

  var body: some View {
    ContentView(store: store)
      .frame(minWidth: 900, minHeight: 600)
      .modifier(OptionalInstantFocusRingModifier(isEnabled: toolbarGlassReproConfiguration.usesInstantFocusRing))
      .modifier(
        HarnessMonitorSceneAppearanceModifier(
          themeMode: $themeMode,
          appliesPreferredColorScheme: !toolbarGlassReproConfiguration.disablesPreferredColorScheme
        )
      )
      .modifier(HarnessMonitorWindowBackdropModifier(mode: backdropMode))
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
    .modifier(
      HarnessMonitorSceneAppearanceModifier(
        themeMode: $themeMode,
        appliesPreferredColorScheme: true
      )
    )
    .modifier(HarnessMonitorUITestAnimationModifier())
  }
}

private struct HarnessMonitorUITestAnimationModifier: ViewModifier {
  private static let isUITesting =
    ProcessInfo.processInfo.environment["HARNESS_MONITOR_UI_TESTS"] == "1"
  private static let keepAnimations =
    ProcessInfo.processInfo.environment["HARNESS_MONITOR_KEEP_ANIMATIONS"] == "1"

  func body(content: Content) -> some View {
    if Self.isUITesting && !Self.keepAnimations {
      content.transaction { $0.disablesAnimations = true }
    } else {
      content
    }
  }
}

private struct OptionalInstantFocusRingModifier: ViewModifier {
  let isEnabled: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    if isEnabled {
      content.instantFocusRing()
    } else {
      content
    }
  }
}

private struct HarnessMonitorSceneAppearanceModifier: ViewModifier {
  @Binding var themeMode: HarnessMonitorThemeMode
  let appliesPreferredColorScheme: Bool
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
      .modifier(
        OptionalPreferredColorSchemeModifier(
          colorScheme: themeMode.colorScheme,
          isEnabled: appliesPreferredColorScheme
        )
      )
      .tint(HarnessMonitorTheme.accent)
      .onAppear(perform: syncThemeFromStorage)
      .onChange(of: storedThemeMode) { _, _ in syncThemeFromStorage() }
      .onChange(of: themeMode) { _, new in persistThemeMode(new) }
  }

  private func syncThemeFromStorage() {
    let nextThemeMode = HarnessMonitorThemeMode(rawValue: storedThemeMode) ?? .auto
    guard themeMode != nextThemeMode else {
      return
    }
    themeMode = nextThemeMode
  }

  private func persistThemeMode(_ newValue: HarnessMonitorThemeMode) {
    let nextRawValue = newValue.rawValue
    guard storedThemeMode != nextRawValue else {
      return
    }
    storedThemeMode = nextRawValue
  }
}

private struct OptionalPreferredColorSchemeModifier: ViewModifier {
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

private struct HarnessMonitorWindowBackdropModifier: ViewModifier {
  let mode: HarnessMonitorBackdropMode

  @ViewBuilder
  func body(content: Content) -> some View {
    switch mode {
    case .none:
      content
    case .window:
      content.containerBackground(for: .window) {
        HarnessMonitorWindowBackdropView()
      }
    case .content:
      content.background {
        HarnessMonitorWindowBackdropView()
      }
    }
  }
}

private struct HarnessMonitorWindowBackdropView: View {
  @Environment(\.colorScheme)
  private var colorScheme
  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency

  private var baseBackground: Color {
    Color(nsColor: .windowBackgroundColor)
  }

  private var topScrimOpacity: Double {
    if reduceTransparency {
      return colorScheme == .dark ? 0.28 : 0.16
    }
    return colorScheme == .dark ? 0.18 : 0.08
  }

  private var successGlowOpacity: Double {
    if reduceTransparency {
      return colorScheme == .dark ? 0.12 : 0.09
    }
    return colorScheme == .dark ? 0.09 : 0.06
  }

  private var accentGlowOpacity: Double {
    if reduceTransparency {
      return colorScheme == .dark ? 0.10 : 0.08
    }
    return colorScheme == .dark ? 0.07 : 0.05
  }

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [
          baseBackground,
          baseBackground,
          HarnessMonitorTheme.ink.opacity(colorScheme == .dark ? 0.08 : 0.03),
        ],
        startPoint: .top,
        endPoint: .bottom
      )

      RadialGradient(
        colors: [
          HarnessMonitorTheme.success.opacity(successGlowOpacity),
          .clear,
        ],
        center: .topLeading,
        startRadius: 24,
        endRadius: 560
      )

      RadialGradient(
        colors: [
          HarnessMonitorTheme.accent.opacity(accentGlowOpacity),
          .clear,
        ],
        center: .bottomTrailing,
        startRadius: 40,
        endRadius: 620
      )

      LinearGradient(
        colors: [
          HarnessMonitorTheme.overlayScrim.opacity(topScrimOpacity),
          .clear,
        ],
        startPoint: .top,
        endPoint: .bottom
      )
    }
    .ignoresSafeArea()
    .accessibilityHidden(true)
  }
}
