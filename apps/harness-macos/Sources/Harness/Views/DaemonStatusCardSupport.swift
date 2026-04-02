import HarnessKit
import SwiftUI

struct DaemonCardHeader: View {
  let connectionLabel: String
  let isLoading: Bool
  let isDaemonOnline: Bool
  let startDaemon: HarnessAsyncActionButton.Action
  let statusTitle: String
  let statusBackground: Color

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
      HStack(spacing: HarnessTheme.itemSpacing) {
        DaemonRestartButton(
          isLoading: isLoading,
          isDaemonOnline: isDaemonOnline,
          startDaemon: startDaemon
        )
        DaemonStatusPill(
          statusTitle: statusTitle,
          statusBackground: statusBackground
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
  let isDaemonOnline: Bool
  let isLaunchAgentInstalled: Bool
  let isLoading: Bool
  let startDaemon: HarnessAsyncActionButton.Action
  let installLaunchAgent: HarnessAsyncActionButton.Action

  var body: some View {
    Group {
      if !isDaemonOnline || !isLaunchAgentInstalled {
        HarnessWrapLayout(spacing: HarnessTheme.itemSpacing, lineSpacing: HarnessTheme.itemSpacing) {
          if !isDaemonOnline {
            DaemonSidebarLayoutProbe(HarnessAccessibility.sidebarStartDaemonButtonFrame) {
              HarnessAsyncActionButton(
                title: "Start Daemon",
                tint: nil,
                variant: .prominent,
                isLoading: isLoading,
                accessibilityIdentifier: HarnessAccessibility.sidebarStartDaemonButton,
                fillsWidth: false,
                action: startDaemon
              )
            }
          }
          if !isLaunchAgentInstalled {
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}

private struct DaemonRestartButton: View {
  let isLoading: Bool
  let isDaemonOnline: Bool
  let startDaemon: HarnessAsyncActionButton.Action

  var body: some View {
    Button {
      guard !isLoading else { return }
      Task { await startDaemon() }
    } label: {
      Image(systemName: isDaemonOnline ? "arrow.clockwise" : "power")
        .scaledFont(.system(.body, weight: .semibold))
    }
    .buttonStyle(DaemonRestartButtonStyle(isLoading: isLoading, isOnline: isDaemonOnline))
    .help(isDaemonOnline ? "Restart daemon" : "Start daemon")
    .accessibilityLabel(isDaemonOnline ? "Restart Daemon" : "Start Daemon")
    .accessibilityIdentifier(HarnessAccessibility.sidebarStartDaemonButton)
  }
}

private struct DaemonStatusPill: View {
  let statusTitle: String
  let statusBackground: Color
  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency
  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast

  var body: some View {
    Text(statusTitle)
      .scaledFont(.caption.bold())
      .harnessPillPadding()
      .background {
        Capsule()
          .fill(statusBackground.opacity(fillOpacity))
      }
      .foregroundStyle(HarnessTheme.onContrast)
      .accessibilityIdentifier(HarnessAccessibility.sidebarDaemonStatusBadge)
      .harnessUITestValue("chrome=flat-status-pill")
  }

  private var fillOpacity: Double {
    if reduceTransparency {
      return colorSchemeContrast == .increased ? 0.72 : 0.62
    }
    return colorSchemeContrast == .increased ? 0.58 : 0.48
  }
}

private struct DaemonStatBadge: View {
  let title: String
  let value: String
  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency
  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title.uppercased())
        .scaledFont(.caption2.weight(.semibold))
        .tracking(HarnessTheme.uppercaseTracking)
        .foregroundStyle(HarnessTheme.secondaryInk)
      Text(value)
        .scaledFont(.system(.callout, design: .rounded, weight: .bold))
        .lineLimit(1)
        .minimumScaleFactor(0.82)
        .contentTransition(.numericText())
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .padding(.horizontal, HarnessTheme.cardPadding)
    .padding(.vertical, HarnessTheme.itemSpacing)
    .background {
      RoundedRectangle(cornerRadius: HarnessTheme.cornerRadiusMD, style: .continuous)
        .fill(.primary.opacity(backgroundFillOpacity))
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(value)
    .accessibilityIdentifier(HarnessAccessibility.sidebarDaemonBadge(title))
  }

  private var backgroundFillOpacity: Double {
    if reduceTransparency {
      return colorSchemeContrast == .increased ? 0.18 : 0.14
    }
    return colorSchemeContrast == .increased ? 0.09 : 0.05
  }
}

private struct DaemonSidebarLayoutProbe<Content: View>: View {
  let identifier: String
  @ViewBuilder let content: Content

  init(_ identifier: String, @ViewBuilder content: () -> Content) {
    self.identifier = identifier
    self.content = content()
  }

  var body: some View {
    content
      .accessibilityFrameMarker(identifier)
  }
}

private struct DaemonRestartButtonStyle: ButtonStyle {
  let isLoading: Bool
  let isOnline: Bool
  @State private var isHovered = false
  @State private var isSpinning = false
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  private static let iconSize: CGFloat = 22

  func makeBody(configuration: Configuration) -> some View {
    let pressed = configuration.isPressed

    configuration.label
      .frame(width: Self.iconSize, height: Self.iconSize)
      .foregroundStyle(iconColor(pressed: pressed))
      .opacity(iconOpacity(pressed: pressed))
      .animation(.easeOut(duration: 0.15), value: isHovered)
      .animation(.easeOut(duration: 0.15), value: isLoading)
      .rotationEffect(isOnline ? rotationAngle : .zero)
      .animation(isOnline ? rotationAnimation : nil, value: isHovered)
      .animation(isOnline ? rotationAnimation : nil, value: isSpinning)
      .scaleEffect(pressScale(pressed: pressed))
      .animation(.spring(duration: 0.2, bounce: 0.3), value: pressed)
      .animation(
        reduceMotion ? nil : .easeInOut(duration: 0.3),
        value: isHovered
      )
      .contentShape(Circle())
      .onContinuousHover { phase in
        switch phase {
        case .active: isHovered = true
        case .ended: isHovered = false
        }
      }
      .onChange(of: isLoading) { _, loading in
        isSpinning = loading && !reduceMotion
      }
  }

  private func pressScale(pressed: Bool) -> CGFloat {
    if pressed { return 0.78 }
    if !isOnline && isHovered && !reduceMotion { return 1.12 }
    return 1
  }

  private var rotationAngle: Angle {
    if isSpinning { return .degrees(360) }
    if isHovered { return .degrees(75) }
    return .zero
  }

  private var rotationAnimation: Animation? {
    if reduceMotion { return .easeOut(duration: 0.1) }
    if isSpinning {
      return .linear(duration: 0.8).repeatForever(autoreverses: false)
    }
    return .spring(duration: 0.35, bounce: 0.15)
  }

  private func iconColor(pressed: Bool) -> Color {
    if isLoading { return HarnessTheme.accent }
    if pressed || isHovered { return isOnline ? HarnessTheme.accent : HarnessTheme.success }
    return HarnessTheme.secondaryInk
  }

  private func iconOpacity(pressed: Bool) -> Double {
    if isLoading { return 0.6 }
    if pressed || isHovered { return 1 }
    return 0.4
  }
}
