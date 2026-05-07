import SwiftUI

public enum HarnessMonitorSidebarSessionRowDisplayMode: String, CaseIterable, Identifiable, Sendable
{
  case concise
  case detailed

  public static let storageKey = "harnessSidebarSessionRowDisplayMode"
  public static let uiTestOverrideKey = "HARNESS_MONITOR_SIDEBAR_SESSION_ROW_DISPLAY_MODE_OVERRIDE"
  public static let defaultMode: Self = .concise

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .concise:
      "Concise"
    case .detailed:
      "Detailed"
    }
  }

  public static func resolved(rawValue: String?) -> Self {
    Self(rawValue: rawValue ?? "") ?? defaultMode
  }
}

extension EnvironmentValues {
  @Entry public var harnessSidebarSessionRowDisplayMode: HarnessMonitorSidebarSessionRowDisplayMode =
    .defaultMode
}
