import SwiftUI

public struct SettingsAppearanceSection: View {
  @Binding public var themeMode: HarnessMonitorThemeMode
  @AppStorage(HarnessMonitorBackdropDefaults.modeKey)
  private var backdropModeRawValue = HarnessMonitorBackdropMode.none.rawValue
  @AppStorage(HarnessMonitorBackgroundDefaults.imageKey)
  private var backgroundImageRawValue = HarnessMonitorBackgroundSelection.defaultSelection
    .storageValue
  @AppStorage(HarnessMonitorTextSize.storageKey)
  private var textSizeIndex = HarnessMonitorTextSize.defaultIndex
  @AppStorage(HarnessMonitorSidebarSessionRowDisplayMode.storageKey)
  private var sidebarSessionRowDisplayModeRawValue =
    HarnessMonitorSidebarSessionRowDisplayMode.defaultMode.rawValue
  #if HARNESS_FEATURE_LOTTIE
    @AppStorage(HarnessMonitorCornerAnimationDefaults.enabledKey)
    private var cornerAnimationEnabled = false
  #endif
  @State private var selectedBackgroundTab: BackgroundCollectionTab = .featured

  public init(themeMode: Binding<HarnessMonitorThemeMode>) {
    _themeMode = themeMode
  }

  private var selectedBackground: HarnessMonitorBackgroundSelection {
    HarnessMonitorBackgroundSelection.decode(backgroundImageRawValue)
  }

  private var sidebarSessionRowDisplayMode: Binding<HarnessMonitorSidebarSessionRowDisplayMode> {
    Binding(
      get: {
        HarnessMonitorSidebarSessionRowDisplayMode.resolved(
          rawValue: sidebarSessionRowDisplayModeRawValue
        )
      },
      set: { sidebarSessionRowDisplayModeRawValue = $0.rawValue }
    )
  }

  public var body: some View {
    Form {
      Section {
        Picker("Theme mode", selection: $themeMode) {
          ForEach(HarnessMonitorThemeMode.allCases) {
            Text($0.label).tag($0)
          }
        }
        .harnessNativeFormControl()
        .accessibilityHint("Changes the color scheme for all windows")
        .accessibilityIdentifier(HarnessMonitorAccessibility.settingsThemeModePicker)

        Picker("Text size", selection: $textSizeIndex) {
          ForEach(Array(HarnessMonitorTextSize.scales.enumerated()), id: \.offset) { index, level in
            Text(level.label).tag(index)
          }
        }
        .harnessNativeFormControl()
        .accessibilityHint("Scales text throughout the application")
        .accessibilityIdentifier(HarnessMonitorAccessibility.settingsTextSizePicker)

        Picker("Sidebar session rows", selection: sidebarSessionRowDisplayMode) {
          ForEach(HarnessMonitorSidebarSessionRowDisplayMode.allCases) { mode in
            Text(mode.label).tag(mode)
          }
        }
        .harnessNativeFormControl()
        .accessibilityHint(
          "Switches the main sidebar between concise rows and detailed rows with more metadata"
        )
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.settingsSidebarSessionRowDisplayModePicker
        )

        Picker("Backdrop", selection: $backdropModeRawValue) {
          ForEach(HarnessMonitorBackdropMode.allCases) { mode in
            Text(mode.label).tag(mode.rawValue)
          }
        }
        .harnessNativeFormControl()
        .accessibilityHint("Controls where the background image renders")
        .accessibilityIdentifier(HarnessMonitorAccessibility.settingsBackdropModePicker)

        #if HARNESS_FEATURE_LOTTIE
          Toggle("Corner animation", isOn: $cornerAnimationEnabled)
            .harnessNativeFormControl()
            .accessibilityHint("Shows a dancing llama during activity")
            .accessibilityIdentifier("harness.settings.appearance.cornerAnimation")
        #endif
      } header: {
        Text("Appearance")
      } footer: {
        Text(appearanceFooterText)
      }

      backgroundImageSection
    }
    .settingsDetailFormStyle()
    .onAppear(perform: selectTabForCurrentBackground)
    .onChange(of: selectedBackground.storageValue) { _, _ in
      selectTabForCurrentBackground()
    }
  }

  private var appearanceFooterText: String {
    var parts = [
      "Theme mode, text size, and sidebar session rows apply to every Harness Monitor window.",
      "Backdrop controls where the softened background image renders, and choosing an image turns on the window backdrop if it is currently off.",
    ]
    #if HARNESS_FEATURE_LOTTIE
      parts.append("Corner animation shows a dancing llama during activity.")
    #endif
    return parts.joined(separator: " ")
  }

  private var isBackdropDisabled: Bool {
    HarnessMonitorBackdropMode(rawValue: backdropModeRawValue) == HarnessMonitorBackdropMode.none
  }

  private var backgroundImageSection: some View {
    HarnessMonitorTabbedContent(
      title: "Background image",
      selection: $selectedBackgroundTab,
      tabTitle: \.title,
      alignment: .trailing,
      tabsDisabled: isBackdropDisabled,
      pickerAccessibilityIdentifier: HarnessMonitorAccessibility
        .settingsBackgroundCollectionPicker
    ) { tab in
      SettingsBackgroundGallery(
        selection: $backgroundImageRawValue,
        backdropModeRawValue: $backdropModeRawValue,
        selectedBackground: selectedBackground,
        collection: tab.collection
      )
    }
  }

  private func selectTabForCurrentBackground() {
    if case .system = selectedBackground.source {
      selectedBackgroundTab = .native
    }
  }
}

private enum BackgroundCollectionTab: String, CaseIterable, Identifiable {
  case featured
  case native

  var id: String { rawValue }

  var title: String {
    switch self {
    case .featured:
      "Featured"
    case .native:
      "Native"
    }
  }

  var collection: BackgroundCollection {
    switch self {
    case .featured:
      .featured
    case .native:
      .native
    }
  }
}

enum BackgroundCollection {
  case featured
  case native
}
