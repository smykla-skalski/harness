import HarnessMonitorKit
import HarnessMonitorUI
import os
import SwiftUI

struct HarnessMonitorWindowRootView: View {
  let delegate: HarnessMonitorAppDelegate
  let store: HarnessMonitorStore
  @Binding var themeMode: HarnessMonitorThemeMode
  let perfScenario: HarnessMonitorPerfScenario?
  @Environment(\.openWindow)
  private var openWindow
  @AppStorage(HarnessMonitorBackdropDefaults.modeKey)
  private var backdropModeRawValue = HarnessMonitorBackdropMode.none.rawValue
  @AppStorage(HarnessMonitorBackgroundDefaults.imageKey)
  private var backgroundImageRawValue = HarnessMonitorBackgroundSelection.defaultSelection.storageValue
  @AppStorage(HarnessMonitorCornerAnimationDefaults.enabledKey)
  private var cornerAnimationEnabled = false
  @State private var hasRunPerfScenario = false
  private let toolbarGlassReproConfiguration = ToolbarGlassReproConfiguration.current

  private var backdropMode: HarnessMonitorBackdropMode {
    HarnessMonitorBackdropMode(rawValue: backdropModeRawValue) ?? .none
  }

  private var backgroundImage: HarnessMonitorBackgroundSelection {
    HarnessMonitorBackgroundSelection.decode(backgroundImageRawValue)
  }

  var body: some View {
    ContentView(
      store: store,
      cornerAnimationContent: cornerAnimationEnabled ? {
        AnyView(HarnessMonitorAppLlamaAnimation())
      } : nil
    )
      .frame(minWidth: 900, minHeight: 600)
      .modifier(
        OptionalInstantFocusRingModifier(
          isEnabled: toolbarGlassReproConfiguration.usesInstantFocusRing
        )
      )
      .modifier(
        HarnessMonitorSceneAppearanceModifier(
          themeMode: $themeMode,
          appliesPreferredColorScheme: !toolbarGlassReproConfiguration.disablesPreferredColorScheme
        )
      )
      .modifier(
        HarnessMonitorWindowBackdropModifier(
          mode: backdropMode,
          backgroundImage: backgroundImage
        )
      )
      .modifier(HarnessMonitorUITestAnimationModifier())
      .task {
        delegate.bind(store: store)
        guard let perfScenario else {
          await store.bootstrapIfNeeded()
          return
        }
        guard !hasRunPerfScenario else {
          return
        }
        hasRunPerfScenario = true
        if perfScenario.includesBootstrapInMeasurement {
          await HarnessMonitorPerfDriver.run(
            scenario: perfScenario,
            store: store,
            openWindow: openWindow
          )
          return
        }
        await store.bootstrapIfNeeded()
        await HarnessMonitorPerfDriver.run(
          scenario: perfScenario,
          store: store,
          openWindow: openWindow
        )
      }
  }
}

struct HarnessMonitorSettingsRootView: View {
  let store: HarnessMonitorStore
  @Binding var themeMode: HarnessMonitorThemeMode
  @State private var selectedSection: PreferencesSection
  @AppStorage(HarnessMonitorBackdropDefaults.modeKey)
  private var backdropModeRawValue = HarnessMonitorBackdropMode.none.rawValue
  @AppStorage(HarnessMonitorBackgroundDefaults.imageKey)
  private var backgroundImageRawValue = HarnessMonitorBackgroundSelection.defaultSelection.storageValue

  init(
    store: HarnessMonitorStore,
    themeMode: Binding<HarnessMonitorThemeMode>,
    initialSection: PreferencesSection = .general
  ) {
    self.store = store
    _themeMode = themeMode
    _selectedSection = State(initialValue: initialSection)
  }

  private var backdropMode: HarnessMonitorBackdropMode {
    HarnessMonitorBackdropMode(rawValue: backdropModeRawValue) ?? .none
  }

  private var backgroundImage: HarnessMonitorBackgroundSelection {
    HarnessMonitorBackgroundSelection.decode(backgroundImageRawValue)
  }

  var body: some View {
    PreferencesView(
      store: store,
      themeMode: $themeMode,
      selectedSection: $selectedSection
    )
    .frame(minWidth: 680, minHeight: 440)
    .modifier(
      HarnessMonitorWindowBackdropModifier(
        mode: backdropMode,
        backgroundImage: backgroundImage
      )
    )
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

@MainActor
private enum HarnessMonitorPerfDriver {
  private static let signposter = OSSignposter(subsystem: "io.harnessmonitor", category: "perf")
  private static let stepDelay: Duration = envMilliseconds(
    "HARNESS_MONITOR_PERF_STEP_DELAY_MS", fallback: 450
  )
  private static let shortDelay: Duration = envMilliseconds(
    "HARNESS_MONITOR_PERF_SHORT_DELAY_MS", fallback: 180
  )

  private static func envMilliseconds(_ key: String, fallback: Int) -> Duration {
    guard let raw = ProcessInfo.processInfo.environment[key],
          let value = Int(raw), value > 0
    else {
      return .milliseconds(fallback)
    }
    return .milliseconds(value)
  }

  static func run(
    scenario: HarnessMonitorPerfScenario,
    store: HarnessMonitorStore,
    openWindow: OpenWindowAction
  ) async {
    let signpostName = scenario.signpostName
    let state = signposter.beginAnimationInterval(signpostName)

    switch scenario {
    case .launchDashboard:
      await store.bootstrapIfNeeded()
      await settle()
    case .selectSessionCockpit:
      await settle()
      await store.selectSession(PreviewFixtures.summary.sessionId)
      await settle()
    case .refreshAndSearch:
      await settle()
      await store.refresh()
      await runSearchPasses(
        queries: ["timeline", "observer", "blocked"],
        store: store
      )
    case .sidebarOverflowSearch:
      await settle()
      await runSearchPasses(
        queries: ["sidebar", "search", "observer", "blocked", "transport"],
        store: store
      )
    case .settingsBackdropCycle:
      await openAppearanceSettings(openWindow: openWindow)
      await cycleBackdropModes()
    case .settingsBackgroundCycle:
      await openAppearanceSettings(openWindow: openWindow)
      await cycleBackgroundSelections()
    case .timelineBurst:
      await settle()
      await store.selectSession(PreviewFixtures.summary.sessionId)
      await burstTimeline(store: store)
    case .offlineCachedOpen:
      await settle()
    }

    signposter.endInterval(signpostName, state)
  }

  private static func settle(_ delay: Duration = .milliseconds(900)) async {
    try? await Task.sleep(for: delay)
  }

  private static func runSearchPasses(
    queries: [String],
    store: HarnessMonitorStore
  ) async {
    for query in queries {
      store.searchText = query
      try? await Task.sleep(for: stepDelay)
    }
    store.searchText = ""
    await settle()
  }

  private static func openAppearanceSettings(openWindow: OpenWindowAction) async {
    UserDefaults.standard.set(
      HarnessMonitorBackdropMode.window.rawValue,
      forKey: HarnessMonitorBackdropDefaults.modeKey
    )
    openWindow(id: HarnessMonitorWindowID.preferences)
    await settle(.milliseconds(1_000))
  }

  private static func cycleBackdropModes() async {
    for mode in HarnessMonitorBackdropMode.allCases + [.window, .content] {
      UserDefaults.standard.set(mode.rawValue, forKey: HarnessMonitorBackdropDefaults.modeKey)
      try? await Task.sleep(for: stepDelay)
    }
    await settle()
  }

  private static func cycleBackgroundSelections() async {
    UserDefaults.standard.set(
      HarnessMonitorBackdropMode.window.rawValue,
      forKey: HarnessMonitorBackdropDefaults.modeKey
    )

    let backgrounds = Array(
      HarnessMonitorBackgroundSelection.bundledLibrary.prefix(6)
    ) + [HarnessMonitorBackgroundSelection.defaultSelection]

    for background in backgrounds {
      UserDefaults.standard.set(
        background.storageValue,
        forKey: HarnessMonitorBackgroundDefaults.imageKey
      )
      try? await Task.sleep(for: stepDelay)
    }

    await settle()
  }

  private static func burstTimeline(store: HarnessMonitorStore) async {
    for batch in 1...8 {
      store.timeline = PreviewFixtures.timelineBurst(batch: batch)
      try? await Task.sleep(for: shortDelay)
    }
    await settle()
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

private extension HarnessMonitorPerfScenario {
  var includesBootstrapInMeasurement: Bool {
    switch self {
    case .launchDashboard:
      true
    case .selectSessionCockpit,
      .refreshAndSearch,
      .sidebarOverflowSearch,
      .settingsBackdropCycle,
      .settingsBackgroundCycle,
      .timelineBurst,
      .offlineCachedOpen:
      false
    }
  }

  var signpostName: StaticString {
    switch self {
    case .launchDashboard: "launch-dashboard"
    case .selectSessionCockpit: "select-session-cockpit"
    case .refreshAndSearch: "refresh-and-search"
    case .sidebarOverflowSearch: "sidebar-overflow-search"
    case .settingsBackdropCycle: "settings-backdrop-cycle"
    case .settingsBackgroundCycle: "settings-background-cycle"
    case .timelineBurst: "timeline-burst"
    case .offlineCachedOpen: "offline-cached-open"
    }
  }
}
