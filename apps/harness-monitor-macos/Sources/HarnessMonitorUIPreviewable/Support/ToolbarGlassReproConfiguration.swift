import Foundation

public struct ToolbarGlassReproConfiguration: Sendable {
  private static let forceInstantFocusRingKey = "HARNESS_MONITOR_FORCE_INSTANT_FOCUS_RING"
  private static let disableContentDetailChromeKey = "HARNESS_MONITOR_DISABLE_CONTENT_DETAIL_CHROME"
  private static let disableToolbarBaselineOverlayKey =
    "HARNESS_MONITOR_DISABLE_TOOLBAR_BASELINE_OVERLAY"
  private static let disablePreferredColorSchemeKey =
    "HARNESS_MONITOR_DISABLE_PREFERRED_COLOR_SCHEME"

  public static let current = Self()

  public let usesInstantFocusRing: Bool
  public let disablesContentDetailChrome: Bool
  public let disablesToolbarBaselineOverlay: Bool
  public let disablesPreferredColorScheme: Bool

  public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    usesInstantFocusRing = environment[Self.forceInstantFocusRingKey] == "1"
    disablesContentDetailChrome = environment[Self.disableContentDetailChromeKey] == "1"
    disablesToolbarBaselineOverlay = environment[Self.disableToolbarBaselineOverlayKey] == "1"
    disablesPreferredColorScheme = environment[Self.disablePreferredColorSchemeKey] == "1"
  }
}
