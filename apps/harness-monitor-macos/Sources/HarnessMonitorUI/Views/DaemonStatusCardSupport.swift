import HarnessMonitorKit
import SwiftUI

private final class DaemonLaunchdIconBundleToken {}

private let daemonLaunchdIconBundle = Bundle(for: DaemonLaunchdIconBundleToken.self)

struct DaemonCardHeader: View {
  let store: HarnessMonitorStore
  let connectionLabel: String
  let isLoading: Bool
  let isDaemonOnline: Bool
  let isLaunchAgentInstalled: Bool
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
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      Spacer()
      HStack(spacing: 8) {
        Group {
          if isLaunchAgentInstalled {
            Image("LaunchDaemonRocket", bundle: daemonLaunchdIconBundle)
              .renderingMode(.template)
              .resizable()
              .scaledToFit()
              .frame(width: 18, height: 18)
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              .opacity(0.6)
              .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarLaunchdStatusIcon)
          } else {
            Image(systemName: "person.fill")
              .scaledFont(.system(.callout, weight: .semibold))
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              .opacity(0.55)
          }
        }
        .help(isLaunchAgentInstalled ? "Launchd managed daemon" : "Manually started daemon")
        .accessibilityLabel(isLaunchAgentInstalled ? "Launchd mode" : "Manual mode")

        DaemonSidebarLayoutProbe(HarnessMonitorAccessibility.sidebarStartDaemonButtonFrame) {
          DaemonStateToggleControl(
            store: store,
            isLoading: isLoading,
            isDaemonOnline: isDaemonOnline,
            statusTitle: statusTitle,
            statusColor: statusColor
          )
        }
      }
    }
  }
}

struct DaemonActionButtons: View {
  let store: HarnessMonitorStore
  let isLaunchAgentInstalled: Bool
  let isLoading: Bool

  var body: some View {
    Group {
      if !isLaunchAgentInstalled {
        HarnessMonitorWrapLayout(
          spacing: HarnessMonitorTheme.itemSpacing,
          lineSpacing: HarnessMonitorTheme.itemSpacing
        ) {
          DaemonSidebarLayoutProbe(HarnessMonitorAccessibility.sidebarInstallLaunchAgentButtonFrame) {
            HarnessMonitorAsyncActionButton(
              title: "Install Launch Agent",
              tint: .secondary,
              variant: .bordered,
              isLoading: isLoading,
              accessibilityIdentifier: HarnessMonitorAccessibility.sidebarInstallLaunchAgentButton,
              fillsWidth: false
            ) {
              await store.installLaunchAgent()
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}

private struct DaemonStateToggleControl: View {
  let store: HarnessMonitorStore
  let isLoading: Bool
  let isDaemonOnline: Bool
  let statusTitle: String
  let statusColor: Color
  @State private var isHovered = false
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
          await store.stopDaemon()
        } else {
          await store.startDaemon()
        }
      }
    } label: {
      ZStack {
        dotLayer
        powerLayer
      }
      .frame(width: 24, height: 24)
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
    .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarStartDaemonButton)
    .overlay {
      AccessibilityTextMarker(
        identifier: HarnessMonitorAccessibility.sidebarDaemonStatusBadge,
        text: statusTitle
      )
      .frame(width: 12, height: 12)
    }
    .harnessUITestValue(isHovered ? "chrome=power" : "chrome=status-dot")
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
    if isLoading { return HarnessMonitorTheme.secondaryInk }
    return isDaemonOnline ? HarnessMonitorTheme.danger : HarnessMonitorTheme.success
  }

  private var morphAnimation: Animation? {
    if reduceMotion {
      return .easeOut(duration: 0.12)
    }
    return .interactiveSpring(response: 0.42, dampingFraction: 0.78, blendDuration: 0.18)
  }

  private var morphProgress: CGFloat {
    isHovered ? 1 : 0
  }

  private var powerRotationDegrees: Double {
    Double(-95 + (95 * morphProgress))
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
