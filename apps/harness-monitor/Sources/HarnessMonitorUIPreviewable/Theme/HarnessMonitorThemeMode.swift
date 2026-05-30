import Foundation
import SwiftUI

public enum HarnessMonitorThemeDefaults {
  public static let modeKey = "harnessThemeMode"
}

public enum HarnessMonitorBackdropDefaults {
  public static let modeKey = "harnessBackdropMode"
}

public enum PolicyCanvasThemeDefaults {
  public static let modeKey = "policyCanvasThemeMode"
}

public enum HarnessMonitorBackgroundDefaults {
  public static let imageKey = "harnessBackgroundImage"
  public static let recentKey = "harnessRecentBackgrounds"
}

public enum HarnessMonitorAgentTuiDefaults {
  public static let submitSendsEnterKey = "harnessAgentTuiSubmitSendsEnter"
  public static let submitSendsEnterDefault = false
}

public enum HarnessMonitorMenuBarDefaults {
  public static let stateColorVariantsEnabledKey =
    "harnessMenuBarStateColorVariantsEnabled"
  public static let stateColorVariantsEnabledDefault = true

  public static func registrationDefaults() -> [String: Any] {
    [stateColorVariantsEnabledKey: stateColorVariantsEnabledDefault]
  }
}

public enum HarnessMonitorSessionTitleBlurDefaults {
  public static let enabledKey = "harnessSessionTitleBlurEnabled"
  public static let enabledDefault = true

  public static func registrationDefaults() -> [String: Any] {
    [enabledKey: enabledDefault]
  }
}

public struct HarnessMonitorBackgroundSelection: Equatable, Identifiable, Sendable {
  public enum Source: Equatable, Sendable {
    case bundled(HarnessMonitorBackgroundImage)
    case system(HarnessMonitorSystemWallpaper)
  }

  public let source: Source
  public let storageValue: String
  public let label: String
  public let subtitle: String
  public let accessibilityKey: String
  public let settingsStateValue: String

  public static let defaultSelection = Self.bundled(.defaultSelection)
  public static let bundledLibrary = HarnessMonitorBackgroundImage.allCases.map(Self.bundled)
  public static var systemLibrary: [Self] {
    HarnessMonitorSystemWallpaper.available.map(Self.system)
  }

  public var id: String { storageValue }

  public static func decode(_ rawValue: String) -> Self {
    if let image = HarnessMonitorBackgroundImage(rawValue: rawValue) {
      return .bundled(image)
    }

    if let bundledRawValue = rawValue.removingPrefix("bundle:") {
      let image = HarnessMonitorBackgroundImage(rawValue: bundledRawValue)
      if let image {
        return .bundled(image)
      }
    }

    if let wallpaper = HarnessMonitorSystemWallpaper.wallpaper(for: rawValue) {
      return .system(wallpaper)
    }

    return defaultSelection
  }

  public static func bundled(_ image: HarnessMonitorBackgroundImage) -> Self {
    Self(
      source: .bundled(image),
      storageValue: image.rawValue,
      label: image.label,
      subtitle: image.subtitle,
      accessibilityKey: image.rawValue,
      settingsStateValue: image.rawValue
    )
  }

  public static func system(_ wallpaper: HarnessMonitorSystemWallpaper) -> Self {
    Self(
      source: .system(wallpaper),
      storageValue: wallpaper.selectionToken,
      label: wallpaper.label,
      subtitle: wallpaper.subtitle,
      accessibilityKey: wallpaper.selectionToken,
      settingsStateValue: wallpaper.selectionToken
    )
  }
}

extension String {
  fileprivate func removingPrefix(_ prefix: String) -> String? {
    guard hasPrefix(prefix) else {
      return nil
    }

    return String(dropFirst(prefix.count))
  }

  var nonEmpty: String? {
    isEmpty ? nil : self
  }
}

public enum HarnessMonitorThemeMode: String, CaseIterable, Identifiable {
  case auto
  case light
  case dark

  public var id: String { rawValue }

  public var colorScheme: ColorScheme? {
    switch self {
    case .auto: nil
    case .light: .light
    case .dark: .dark
    }
  }

  public var label: String {
    switch self {
    case .auto: "Auto"
    case .light: "Light"
    case .dark: "Dark"
    }
  }
}

public enum PolicyCanvasThemeMode: String, CaseIterable, Identifiable, Sendable {
  case useAppTheme
  case light
  case dark

  public static let defaultValue: Self = .useAppTheme

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .useAppTheme: "Use App Theme"
    case .light: "Light"
    case .dark: "Dark"
    }
  }

  public func resolvedThemeMode(appThemeMode: HarnessMonitorThemeMode) -> HarnessMonitorThemeMode {
    switch self {
    case .useAppTheme: appThemeMode
    case .light: .light
    case .dark: .dark
    }
  }

  public func resolvedColorScheme(appThemeMode: HarnessMonitorThemeMode) -> ColorScheme? {
    resolvedThemeMode(appThemeMode: appThemeMode).colorScheme
  }
}

private struct PolicyCanvasThemeScopeModifier: ViewModifier {
  @AppStorage(HarnessMonitorThemeDefaults.modeKey)
  private var appThemeMode = HarnessMonitorThemeMode.auto
  @AppStorage(PolicyCanvasThemeDefaults.modeKey)
  private var canvasThemeMode = PolicyCanvasThemeMode.defaultValue

  func body(content: Content) -> some View {
    content
      .transformEnvironment(\.colorScheme) { colorScheme in
        if let resolvedColorScheme = canvasThemeMode.resolvedColorScheme(
          appThemeMode: appThemeMode
        ) {
          colorScheme = resolvedColorScheme
        }
      }
  }
}

extension View {
  func policyCanvasThemeScope() -> some View {
    modifier(PolicyCanvasThemeScopeModifier())
  }
}

public enum HarnessMonitorBackgroundImage: String, CaseIterable, Identifiable, Sendable {
  case auroraVeil
  case blueMarble
  case aleutianCloudbreak
  case andesRelief
  case eastCaicos
  case gangesDelta
  case turksAndCaicos
  case canaryCaldera
  case icefallAntarctica
  case spiralGalaxy

  public static let defaultSelection: Self = .auroraVeil

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .auroraVeil: "Aurora Veil"
    case .blueMarble: "Blue Marble"
    case .aleutianCloudbreak: "Cloudbreak"
    case .andesRelief: "Andes Relief"
    case .eastCaicos: "East Caicos"
    case .gangesDelta: "River Delta"
    case .turksAndCaicos: "Turks & Caicos"
    case .canaryCaldera: "Canary Caldera"
    case .icefallAntarctica: "Icefall"
    case .spiralGalaxy: "Spiral Galaxy"
    }
  }

  public var subtitle: String {
    switch self {
    case .auroraVeil: "Red-green atmospheric horizon"
    case .blueMarble: "Planet-scale deep blue"
    case .aleutianCloudbreak: "Silver cloud bands over Alaska"
    case .andesRelief: "Snow ridges and glacial lakes"
    case .eastCaicos: "Shallow turquoise coastal shelf"
    case .gangesDelta: "Braided estuary channels"
    case .turksAndCaicos: "Turquoise cays in deep blue"
    case .canaryCaldera: "Volcanic island relief"
    case .icefallAntarctica: "Abstract Antarctic ice texture"
    case .spiralGalaxy: "Luminous deep-space spiral"
    }
  }

  public var assetName: String {
    switch self {
    case .auroraVeil: "BackgroundAuroraVeil"
    case .blueMarble: "BackgroundBlueMarble"
    case .aleutianCloudbreak: "BackgroundAleutianCloudbreak"
    case .andesRelief: "BackgroundAndesRelief"
    case .eastCaicos: "BackgroundEastCaicos"
    case .gangesDelta: "BackgroundGangesDelta"
    case .turksAndCaicos: "BackgroundTurksAndCaicos"
    case .canaryCaldera: "BackgroundCanaryCaldera"
    case .icefallAntarctica: "BackgroundIcefallAntarctica"
    case .spiralGalaxy: "BackgroundSpiralGalaxy"
    }
  }
}

public enum HarnessMonitorBackdropMode: String, CaseIterable, Identifiable {
  case none
  case window
  case content

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .none: "None"
    case .window: "Window"
    case .content: "Content"
    }
  }
}
