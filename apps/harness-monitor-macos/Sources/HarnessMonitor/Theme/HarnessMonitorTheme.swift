import HarnessMonitorKit
import SwiftUI

private func harnessColor(_ name: String) -> Color {
  Color(name, bundle: .main)
}

enum HarnessMonitorTheme {
  static let accent = harnessColor("HarnessMonitorAccent")
  static let ink = harnessColor("HarnessMonitorInk")
  static let warmAccent = harnessColor("HarnessMonitorWarmAccent")
  static let success = harnessColor("HarnessMonitorSuccess")
  static let caution = harnessColor("HarnessMonitorCaution")
  static let danger = harnessColor("HarnessMonitorDanger")
  static let controlBorder = harnessColor("HarnessMonitorControlBorder")
  static let overlayScrim = harnessColor("HarnessMonitorOverlayScrim")
  static let secondaryInk = ink.opacity(0.88)
  static let tertiaryInk = ink.opacity(0.76)
  static let onContrast = Color.white

  static let spacingXS: CGFloat = 4
  static let spacingSM: CGFloat = 8
  static let spacingMD: CGFloat = 12
  static let spacingLG: CGFloat = 16
  static let spacingXL: CGFloat = 20
  static let spacingXXL: CGFloat = 24

  static let cardPadding: CGFloat = spacingMD
  static let pillPaddingH: CGFloat = spacingSM
  static let pillPaddingV: CGFloat = spacingXS
  static let sectionSpacing: CGFloat = spacingMD
  static let itemSpacing: CGFloat = spacingSM
  static let uppercaseTracking: CGFloat = 0.5
  static let cornerRadiusSM: CGFloat = 12
  static let cornerRadiusMD: CGFloat = 16
  static let cornerRadiusLG: CGFloat = 20
}

func statusColor(for status: SessionStatus) -> Color {
  switch status {
  case .active:
    HarnessMonitorTheme.success
  case .paused:
    HarnessMonitorTheme.caution
  case .ended:
    HarnessMonitorTheme.ink.opacity(0.55)
  }
}

func severityColor(for severity: TaskSeverity) -> Color {
  switch severity {
  case .low:
    HarnessMonitorTheme.accent.opacity(0.7)
  case .medium:
    HarnessMonitorTheme.accent
  case .high:
    HarnessMonitorTheme.warmAccent
  case .critical:
    HarnessMonitorTheme.danger
  }
}

func signalStatusColor(for status: SessionSignalStatus) -> Color {
  switch status {
  case .pending, .deferred:
    HarnessMonitorTheme.caution
  case .acknowledged:
    HarnessMonitorTheme.success
  case .rejected, .expired:
    HarnessMonitorTheme.danger
  }
}

func taskStatusColor(for status: TaskStatus) -> Color {
  switch status {
  case .open:
    HarnessMonitorTheme.accent
  case .inProgress:
    HarnessMonitorTheme.warmAccent
  case .inReview:
    HarnessMonitorTheme.caution
  case .done:
    HarnessMonitorTheme.success
  case .blocked:
    HarnessMonitorTheme.danger
  }
}
