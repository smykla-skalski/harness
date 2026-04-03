import SwiftUI

public enum HarnessMonitorThemeDefaults {
  public static let modeKey = "harnessThemeMode"
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
