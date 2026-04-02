import HarnessKit
import SwiftUI

private func harnessColor(_ name: String) -> Color {
  Color(name, bundle: .main)
}

enum HarnessTheme {
  static let accent = harnessColor("HarnessAccent")
  static let ink = harnessColor("HarnessInk")
  static let warmAccent = harnessColor("HarnessWarmAccent")
  static let success = harnessColor("HarnessSuccess")
  static let caution = harnessColor("HarnessCaution")
  static let danger = harnessColor("HarnessDanger")
  static let controlBorder = harnessColor("HarnessControlBorder")
  static let overlayScrim = harnessColor("HarnessOverlayScrim")
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
    HarnessTheme.success
  case .paused:
    HarnessTheme.caution
  case .ended:
    HarnessTheme.ink.opacity(0.55)
  }
}

func severityColor(for severity: TaskSeverity) -> Color {
  switch severity {
  case .low:
    HarnessTheme.accent.opacity(0.7)
  case .medium:
    HarnessTheme.accent
  case .high:
    HarnessTheme.warmAccent
  case .critical:
    HarnessTheme.danger
  }
}

func signalStatusColor(for status: SessionSignalStatus) -> Color {
  switch status {
  case .pending, .deferred:
    HarnessTheme.caution
  case .acknowledged:
    HarnessTheme.success
  case .rejected, .expired:
    HarnessTheme.danger
  }
}

func taskStatusColor(for status: TaskStatus) -> Color {
  switch status {
  case .open:
    HarnessTheme.accent
  case .inProgress:
    HarnessTheme.warmAccent
  case .inReview:
    HarnessTheme.caution
  case .done:
    HarnessTheme.success
  case .blocked:
    HarnessTheme.danger
  }
}
