import HarnessMonitorKit
import SwiftUI

public enum WorkspaceAttentionBadgeStyle {
  public static func badgeColor(for severity: DecisionSeverity?) -> Color {
    switch severity {
    case .none, .info:
      .secondary
    case .warn, .needsUser:
      .orange
    case .critical:
      .red
    }
  }

  public static func tintLabel(for severity: DecisionSeverity?) -> String {
    switch severity {
    case .none, .info:
      "secondary"
    case .warn, .needsUser:
      "orange"
    case .critical:
      "red"
    }
  }
}
