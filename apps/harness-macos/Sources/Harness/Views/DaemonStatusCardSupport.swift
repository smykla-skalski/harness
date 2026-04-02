import HarnessKit
import SwiftUI

struct DaemonCardHeader: View {
  let connectionLabel: String
  let isLoading: Bool
  let isDaemonOnline: Bool
  let startDaemon: HarnessAsyncActionButton.Action
  let stopDaemon: HarnessAsyncActionButton.Action
  let statusTitle: String
  let statusColor: Color

  var body: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Daemon")
          .scaledFont(.system(.title3, design: .rounded, weight: .bold))
          .accessibilityAddTraits(.isHeader)
        Text(connectionLabel)
          .scaledFont(.system(.subheadline, design: .rounded, weight: .medium))
          .foregroundStyle(HarnessTheme.secondaryInk)
      }
      Spacer()
      DaemonSidebarLayoutProbe(HarnessAccessibility.sidebarStartDaemonButtonFrame) {
        DaemonStateToggleControl(
          isLoading: isLoading,
          isDaemonOnline: isDaemonOnline,
          startDaemon: startDaemon,
          stopDaemon: stopDaemon,
          statusTitle: statusTitle,
          statusColor: statusColor
        )
      }
    }
  }
}

struct DaemonMetricsStrip: View {
  let projectCount: Int
  let sessionCount: Int
  let launchdState: String

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: HarnessTheme.itemSpacing) {
        projectsBadge
        sessionsBadge
        launchdBadge
      }
      VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
        HStack(spacing: HarnessTheme.itemSpacing) {
          projectsBadge
          sessionsBadge
        }
        launchdBadge
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var projectsBadge: some View {
    DaemonSidebarLayoutProbe(HarnessAccessibility.sidebarDaemonBadgeFrame("Projects")) {
      DaemonStatBadge(title: "Projects", value: "\(projectCount)")
    }
  }

  private var sessionsBadge: some View {
    DaemonSidebarLayoutProbe(HarnessAccessibility.sidebarDaemonBadgeFrame("Sessions")) {
      DaemonStatBadge(title: "Sessions", value: "\(sessionCount)")
    }
  }

  private var launchdBadge: some View {
    DaemonSidebarLayoutProbe(HarnessAccessibility.sidebarDaemonBadgeFrame("Launchd")) {
      DaemonStatBadge(title: "Launchd", value: launchdState)
    }
  }
}

struct DaemonActionButtons: View {
  let isLaunchAgentInstalled: Bool
  let isLoading: Bool
  let installLaunchAgent: HarnessAsyncActionButton.Action

  var body: some View {
    Group {
      if !isLaunchAgentInstalled {
        HarnessWrapLayout(spacing: HarnessTheme.itemSpacing, lineSpacing: HarnessTheme.itemSpacing) {
          DaemonSidebarLayoutProbe(HarnessAccessibility.sidebarInstallLaunchAgentButtonFrame) {
            HarnessAsyncActionButton(
              title: "Install Launch Agent",
              tint: .secondary,
              variant: .bordered,
              isLoading: isLoading,
              accessibilityIdentifier: HarnessAccessibility.sidebarInstallLaunchAgentButton,
              fillsWidth: false,
              action: installLaunchAgent
            )
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}

private struct DaemonStateToggleControl: View {
  let isLoading: Bool
  let isDaemonOnline: Bool
  let startDaemon: HarnessAsyncActionButton.Action
  let stopDaemon: HarnessAsyncActionButton.Action
  let statusTitle: String
  let statusColor: Color
  @State private var isHovered = false
  @State private var idleHintMorphProgress: CGFloat = 0
  @State private var idleHintScale: CGFloat = 1
  @State private var idleHintReturningToDot = false
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency
  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast

  var body: some View {
    Button {
      guard !isLoading else { return }
      Task {
        if isDaemonOnline {
          await stopDaemon()
        } else {
          await startDaemon()
        }
      }
    } label: {
      ZStack {
        dotLayer
        powerLayer
      }
      .frame(width: 24, height: 24)
      .scaleEffect(idleHintEffectiveScale)
      .opacity(isLoading ? 0.7 : 1)
      .contentShape(Circle())
    }
    .buttonStyle(DaemonPowerToggleButtonStyle(reduceMotion: reduceMotion))
    .contentShape(Rectangle())
    .onContinuousHover { phase in
      let hovered: Bool = switch phase {
      case .active: true
      case .ended: false
      }
      guard hovered != isHovered else { return }
      withAnimation(morphAnimation) {
        isHovered = hovered
      }
    }
    .help(isDaemonOnline ? "Stop daemon" : "Start daemon")
    .accessibilityLabel(isDaemonOnline ? "Stop Daemon" : "Start Daemon")
    .accessibilityValue(statusTitle)
    .accessibilityIdentifier(HarnessAccessibility.sidebarStartDaemonButton)
    .background {
      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Daemon Status")
        .accessibilityValue(statusTitle)
        .accessibilityIdentifier(HarnessAccessibility.sidebarDaemonStatusBadge)
    }
    .harnessUITestValue(isHovered ? "chrome=power" : "chrome=status-dot")
    .task(id: idleHintTaskID) {
      guard let cycleSeconds = idleHintCycleSeconds else {
        resetIdleHintState()
        return
      }

      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(cycleSeconds))
        if Task.isCancelled { break }
        guard idleHintCycleSeconds != nil, !isHovered else { continue }
        await runIdleHintAnimation()
      }
    }
  }

  private var fillOpacity: Double {
    if reduceTransparency {
      return colorSchemeContrast == .increased ? 0.88 : 0.8
    }
    return colorSchemeContrast == .increased ? 0.76 : 0.66
  }

  private var strokeOpacity: Double {
    colorSchemeContrast == .increased ? 0.92 : 0.72
  }

  private var dotLayer: some View {
    Circle()
      .fill(statusColor.opacity(fillOpacity))
      .frame(width: 12, height: 12)
      .background {
        Circle()
          .strokeBorder(statusColor.opacity(strokeOpacity), lineWidth: 1)
      }
      .opacity(1 - morphProgress)
      .scaleEffect(1 + (0.7 * morphProgress))
      .blur(radius: 2 * morphProgress)
  }

  private var powerLayer: some View {
    Image(systemName: "power")
      .scaledFont(.system(.body, weight: .semibold))
      .foregroundStyle(iconColor)
      .opacity(morphProgress)
      .scaleEffect(0.25 + (0.75 * morphProgress))
      .rotationEffect(.degrees(powerRotationDegrees))
  }

  private var iconColor: Color {
    if isLoading { return HarnessTheme.secondaryInk }
    return isDaemonOnline ? HarnessTheme.danger : HarnessTheme.success
  }

  private var morphAnimation: Animation? {
    if reduceMotion {
      return .easeOut(duration: 0.12)
    }
    return .interactiveSpring(response: 0.42, dampingFraction: 0.78, blendDuration: 0.18)
  }

  private var idleHintCycleSeconds: Double? {
    guard !isLoading else { return nil }
    return isDaemonOnline ? 30 : 10
  }

  private var idleHintTaskID: String {
    if isLoading { return "disabled" }
    return isDaemonOnline ? "online-30" : "offline-10"
  }

  private var morphProgress: CGFloat {
    let progress = isHovered ? 1 : idleHintMorphProgress
    return min(max(progress, 0), 1)
  }

  private var idleHintEffectiveScale: CGFloat {
    isHovered ? 1 : idleHintScale
  }

  @MainActor
  private func runIdleHintAnimation() async {
    withAnimation(.interpolatingSpring(stiffness: 260, damping: 15)) {
      idleHintMorphProgress = 1
      idleHintScale = 1.14
    }
    try? await Task.sleep(for: .milliseconds(120))
    if idleHintCycleSeconds == nil || isHovered { resetIdleHintState(); return }

    withAnimation(.interpolatingSpring(stiffness: 340, damping: 20)) {
      idleHintScale = 0.95
    }
    try? await Task.sleep(for: .milliseconds(110))
    if idleHintCycleSeconds == nil || isHovered { resetIdleHintState(); return }

    withAnimation(.interpolatingSpring(stiffness: 280, damping: 18)) {
      idleHintScale = 1
    }
    try? await Task.sleep(for: .milliseconds(280))
    if idleHintCycleSeconds == nil || isHovered { resetIdleHintState(); return }

    idleHintReturningToDot = true
    withAnimation(.interpolatingSpring(stiffness: 260, damping: 15)) {
      idleHintMorphProgress = 0
      idleHintScale = 1.14
    }
    try? await Task.sleep(for: .milliseconds(120))
    if idleHintCycleSeconds == nil || isHovered { resetIdleHintState(); return }

    withAnimation(.interpolatingSpring(stiffness: 340, damping: 20)) {
      idleHintScale = 0.95
    }
    try? await Task.sleep(for: .milliseconds(110))
    if idleHintCycleSeconds == nil || isHovered { resetIdleHintState(); return }

    withAnimation(.interpolatingSpring(stiffness: 280, damping: 18)) {
      idleHintScale = 1
    }
    try? await Task.sleep(for: .milliseconds(120))
    idleHintReturningToDot = false
  }

  private func resetIdleHintState() {
    idleHintMorphProgress = 0
    idleHintScale = 1
    idleHintReturningToDot = false
  }

  private var powerRotationDegrees: Double {
    if idleHintReturningToDot && !isHovered {
      return Double(95 * (1 - morphProgress))
    }
    return Double(-95 + (95 * morphProgress))
  }
}

private struct DaemonPowerToggleButtonStyle: ButtonStyle {
  let reduceMotion: Bool

  func makeBody(configuration: Configuration) -> some View {
    let isPressed = configuration.isPressed

    configuration.label
      .scaleEffect(isPressed ? 0.9 : 1)
      .offset(y: isPressed ? 0.35 : 0)
      .brightness(isPressed ? -0.03 : 0)
      .saturation(isPressed ? 0.96 : 1)
      .animation(pressAnimation, value: configuration.isPressed)
  }

  private var pressAnimation: Animation? {
    if reduceMotion {
      return .easeOut(duration: 0.08)
    }
    return .interactiveSpring(response: 0.18, dampingFraction: 0.45, blendDuration: 0.14)
  }
}
