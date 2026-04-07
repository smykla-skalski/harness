import HarnessMonitorKit
import SwiftUI

final class HarnessMonitorUIBundleToken {}

public enum HarnessMonitorUIAssets {
  public static let bundle = Bundle(for: HarnessMonitorUIBundleToken.self)

  public static func image(named name: String) -> Image {
    Image(name, bundle: bundle)
  }
}

private func harnessColor(_ name: String) -> Color {
  Color(name, bundle: HarnessMonitorUIAssets.bundle)
}

public enum HarnessMonitorTheme {
  public static let accent = harnessColor("HarnessMonitorAccent")
  public static let ink = harnessColor("HarnessMonitorInk")
  public static let warmAccent = harnessColor("HarnessMonitorWarmAccent")
  public static let success = harnessColor("HarnessMonitorSuccess")
  public static let caution = harnessColor("HarnessMonitorCaution")
  public static let danger = harnessColor("HarnessMonitorDanger")
  public static let controlBorder = harnessColor("HarnessMonitorControlBorder")
  public static let overlayScrim = harnessColor("HarnessMonitorOverlayScrim")
  public static let secondaryInk = ink.opacity(0.88)
  public static let tertiaryInk = ink.opacity(0.76)
  public static let onContrast = Color.white

  public static let spacingXS: CGFloat = 4
  public static let spacingSM: CGFloat = 8
  public static let spacingMD: CGFloat = 12
  public static let spacingLG: CGFloat = 16
  public static let spacingXL: CGFloat = 20
  public static let spacingXXL: CGFloat = 24

  public static let cardPadding: CGFloat = spacingMD
  public static let pillPaddingH: CGFloat = spacingSM
  public static let pillPaddingV: CGFloat = spacingXS
  public static let sectionSpacing: CGFloat = spacingMD
  public static let itemSpacing: CGFloat = spacingSM
  public static let uppercaseTracking: CGFloat = 0.5
  public static let cornerRadiusSM: CGFloat = 12
  public static let cornerRadiusMD: CGFloat = 16
  public static let cornerRadiusLG: CGFloat = 20
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
