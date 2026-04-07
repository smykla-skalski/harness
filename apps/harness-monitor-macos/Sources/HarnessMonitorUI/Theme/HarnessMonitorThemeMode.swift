import SwiftUI

public enum HarnessMonitorThemeDefaults {
  public static let modeKey = "harnessThemeMode"
}

public enum HarnessMonitorBackdropDefaults {
  public static let modeKey = "harnessBackdropMode"
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
