import SwiftUI

public enum HarnessMonitorSidebarSessionRowDisplayMode: String, CaseIterable, Identifiable, Sendable
{
  case strict
  case dense

  public static let storageKey = "harnessSidebarSessionRowDisplayMode"
  public static let uiTestOverrideKey = "HARNESS_MONITOR_SIDEBAR_SESSION_ROW_DISPLAY_MODE_OVERRIDE"
  public static let defaultMode: Self = .strict

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .strict:
      "Strict"
    case .dense:
      "Dense"
    }
  }

  public static func resolved(rawValue: String?) -> Self {
    switch rawValue {
    case "concise":
      .strict
    case "detailed":
      .dense
    default:
      Self(rawValue: rawValue ?? "") ?? defaultMode
    }
  }
}

extension EnvironmentValues {
  @Entry public var harnessSidebarSessionRowDisplayMode:
    HarnessMonitorSidebarSessionRowDisplayMode = .defaultMode
}
