import SwiftUI
import HarnessMonitorPolicyCanvasAlgorithms

enum PolicyCanvasHostThemeDefaults {
  static let modeKey = "harnessThemeMode"
}

public enum PolicyCanvasThemeDefaults {
  public static let modeKey = "policyCanvasThemeMode"
}

enum PolicyCanvasHostThemeMode: String, CaseIterable, Identifiable, Sendable {
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

  func resolvedThemeMode(appThemeMode: PolicyCanvasHostThemeMode) -> PolicyCanvasHostThemeMode {
    switch self {
    case .useAppTheme: appThemeMode
    case .light: .light
    case .dark: .dark
    }
  }

  func resolvedColorScheme(appThemeMode: PolicyCanvasHostThemeMode) -> ColorScheme? {
    resolvedThemeMode(appThemeMode: appThemeMode).colorScheme
  }
}

private struct PolicyCanvasThemeScopeModifier: ViewModifier {
  @AppStorage(PolicyCanvasHostThemeDefaults.modeKey)
  private var appThemeMode = PolicyCanvasHostThemeMode.auto
  @AppStorage(PolicyCanvasThemeDefaults.modeKey)
  private var canvasThemeMode = PolicyCanvasThemeMode.defaultValue

  func body(content: Content) -> some View {
    content.policyCanvasResolvedThemeScope(
      canvasThemeMode.resolvedColorScheme(appThemeMode: appThemeMode)
    )
  }
}

struct PolicyCanvasResolvedThemeScopeModifier: ViewModifier {
  let resolvedColorScheme: ColorScheme?

  func body(content: Content) -> some View {
    content
      .transformEnvironment(\.colorScheme) { colorScheme in
        if let resolvedColorScheme {
          colorScheme = resolvedColorScheme
        }
      }
  }
}

extension View {
  func policyCanvasThemeScope() -> some View {
    modifier(PolicyCanvasThemeScopeModifier())
  }

  func policyCanvasResolvedThemeScope(_ resolvedColorScheme: ColorScheme?) -> some View {
    modifier(PolicyCanvasResolvedThemeScopeModifier(resolvedColorScheme: resolvedColorScheme))
  }
}
