import HarnessMonitorKit
import SwiftUI

// Colour role table for review status surfaces (2026-05-23):
// - `.success`     -> content fully complete and on-track (PR merged;
//                     all required checks passing). Reserved for content
//                     states; the data-source surface deliberately does
//                     NOT reuse green so users learn that green always
//                     means "this PR is good", not "the feed is healthy".
// - `.accent`      -> your action expected next or the data feed is live.
//                     Covers `Live daemon`, `you can approve`, `review
//                     required from you`, and `source live at freshness
//                     ceiling`.
// - `.caution`     -> running, not done (checks in progress; sync in
//                     progress; freshness near ceiling).
// - `.danger`      -> broken or blocked (checks failing; sync error;
//                     daemon offline; requires attention).
// - `.secondaryInk` -> informational only (count; labels; cached state).
//
// `secondaryInk` contrast measurement:
// - dark mode: ink (R 0.900, G 0.910, B 0.930) at 0.88 over canvas
//   (~#1E1E1E) produces a relative luminance of 0.627 against canvas
//   luminance 0.0129, contrast ratio ~10.8:1. Well above WCAG AA (4.5:1)
//   and AAA (7:1) for normal text.
// - light mode: ink (R 0.120, G 0.150, B 0.190) at 0.88 over canvas
//   (~#F0F0F0) produces a relative luminance of 0.0478 against canvas
//   luminance 0.874, contrast ratio ~9.5:1. Also above AA/AAA.
// Conclusion: 0.88 is fine; no bump needed. Re-measure if the ink or
// canvas asset values change.

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
  public static let disabledConnectionChrome = ink.opacity(0.32)
  /// Measured contrast ratio 10.8:1 (dark) / 9.5:1 (light) against canvas.
  /// Above WCAG AAA (7:1). Do not lower without a fresh measurement against
  /// the current ink and canvas asset values.
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
  /// Shared rounded-rect corner radius for tinted pills
  /// (`DashboardReviewMetricPill`, `DashboardReviewStatusPill`,
  /// and review-row label chips). Glass capsule pills handle their own
  /// rounding via `harnessControlPillGlass`.
  public static let pillCornerRadius: CGFloat = 7
  public static let cornerRadiusSM: CGFloat = 12
  public static let cornerRadiusMD: CGFloat = 16
  public static let cornerRadiusLG: CGFloat = 20
}

func statusColor(for status: SessionStatus) -> Color {
  switch status {
  case .awaitingLeader:
    HarnessMonitorTheme.accent
  case .active:
    HarnessMonitorTheme.success
  case .paused:
    HarnessMonitorTheme.caution
  case .leaderlessDegraded:
    HarnessMonitorTheme.caution
  case .ended:
    HarnessMonitorTheme.ink.opacity(0.55)
  }
}

func statusColor(for tone: HarnessMonitorStore.StatusMessageTone) -> Color {
  switch tone {
  case .secondary:
    HarnessMonitorTheme.ink.opacity(0.55)
  case .info:
    HarnessMonitorTheme.accent
  case .success:
    HarnessMonitorTheme.success
  case .caution:
    HarnessMonitorTheme.caution
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
  case .delivered:
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
  case .awaitingReview:
    HarnessMonitorTheme.caution
  case .inReview:
    HarnessMonitorTheme.caution
  case .done:
    HarnessMonitorTheme.success
  case .blocked:
    HarnessMonitorTheme.danger
  }
}

func agentStatusColor(for status: AgentStatus) -> Color {
  switch status {
  case .active:
    HarnessMonitorTheme.success
  case .awaitingReview:
    HarnessMonitorTheme.caution
  case .idle:
    HarnessMonitorTheme.ink.opacity(0.55)
  case .disconnected:
    HarnessMonitorTheme.ink.opacity(0.55)
  case .removed:
    HarnessMonitorTheme.danger
  }
}

func agentTuiStatusColor(for status: AgentTuiStatus) -> Color {
  switch status {
  case .running:
    HarnessMonitorTheme.success
  case .stopped:
    HarnessMonitorTheme.caution
  case .exited:
    HarnessMonitorTheme.ink.opacity(0.55)
  case .failed:
    HarnessMonitorTheme.danger
  }
}
