import HarnessMonitorKit
import SwiftUI

struct SessionWindowToolbar: ToolbarContent {
  let store: HarnessMonitorStore
  let snapshot: HarnessMonitorSessionWindowSnapshot?
  let isLoading: Bool
  let summary: SessionSummary?
  let connectionTitle: String
  let sourceSystemImage: String
  let state: SessionWindowStateCache
  @Binding var focusMode: Bool
  @AppStorage(HarnessMonitorMCPSettingsDefaults.registryHostEnabledKey)
  private var mcpRegistryHostEnabled = HarnessMonitorMCPSettingsDefaults
    .registryHostEnabledDefault
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  private var sleepPreventionPresentation: SleepPreventionToolbarPresentation {
    SleepPreventionToolbarPresentation(isEnabled: store.sleepPreventionEnabled)
  }

  private var sourceTitle: String {
    guard snapshot != nil else {
      return "Loading"
    }
    guard !isLoading, let source = snapshot?.source else {
      return "Refreshing"
    }
    return source.rawValue.capitalized
  }

  private var connectionMetrics: ConnectionMetrics {
    store.connectionMetrics
  }

  private var sourcePresentation: SessionToolbarCenterpieceSourcePresentation {
    .init(
      title: sourceTitle,
      systemImage: sourceSystemImage,
      tint: sourceTint
    )
  }

  private var sourceTint: Color {
    guard !isLoading, let source = snapshot?.source else {
      return HarnessMonitorTheme.tertiaryInk
    }
    switch source {
    case .live:
      return HarnessMonitorTheme.success
    case .cache:
      return HarnessMonitorTheme.secondaryInk
    case .catalog:
      return HarnessMonitorTheme.tertiaryInk
    }
  }

  private var statusStripState: SessionToolbarCenterpieceStatusStripState {
    SessionToolbarCenterpieceStatusStripState(
      daemonOwnership: store.daemonOwnership,
      bridgeRunning: store.daemonStatus?.manifest?.hostBridge.running == true,
      mcpStatus: store.mcpStatus,
      isMCPRegistryHostEnabled: mcpRegistryHostEnabled
    )
  }

  private var sessionStatusTitle: String {
    summary?.status.title ?? "Loading"
  }

  private var connectionSummaryText: String {
    guard connectionMetrics.connectedSince != nil else {
      return "Connection: \(connectionTitle)"
    }
    if let latency = connectionMetrics.transportLatencyMs {
      return
        "Connection: \(connectionMetrics.transportKind.shortTitle), transport latency \(latency) milliseconds"
    }
    if let requestLatency = connectionMetrics.requestLatencyMs {
      return [
        "Connection: \(connectionMetrics.transportKind.shortTitle)",
        "transport latency unavailable,",
        "last request latency \(requestLatency) milliseconds",
      ].joined(separator: " ")
    }
    return "Connection: \(connectionMetrics.transportKind.title)"
  }

  private var sessionStatusAccessibilityValue: String {
    var parts = [
      connectionSummaryText,
      "Source: \(sourcePresentation.title)",
      "Status: \(sessionStatusTitle)",
    ]
    if let bridge = statusStripState.bridge {
      parts.append(bridge.accessibilityValue)
    }
    if let mcp = statusStripState.mcp {
      parts.append(mcp.accessibilityValue)
    }
    return parts.joined(separator: ", ")
  }

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .navigation) {
      Button {
        state.navigateBack()
      } label: {
        Label("Back", systemImage: "chevron.backward")
      }
      .disabled(!state.navigationHistory.canGoBack)
      .help("Go back")
      .accessibilityIdentifier(HarnessMonitorAccessibility.sessionNavigateBackButton)

      Button {
        state.navigateForward()
      } label: {
        Label("Forward", systemImage: "chevron.forward")
      }
      .disabled(!state.navigationHistory.canGoForward)
      .help("Go forward")
      .accessibilityIdentifier(HarnessMonitorAccessibility.sessionNavigateForwardButton)
    }
    ToolbarItem(placement: .automatic) {
      Button {
        toggleFocusMode()
      } label: {
        Label {
          Text("Focus Mode")
        } icon: {
          Image(systemName: focusMode ? "moon.fill" : "moon")
            .contentTransition(
              .symbolEffect(
                .replace.magic(fallback: .downUp.wholeSymbol),
                options: .nonRepeating
              )
            )
            .frame(width: 14, height: 14)
        }
      }
      .help(focusMode ? "Exit focus mode" : "Enter focus mode")
      .accessibilityIdentifier(HarnessMonitorAccessibility.sessionWindowFocusModeButton)
      .accessibilityLabel("Focus mode")
      .accessibilityValue(focusMode ? "On" : "Off")
      .accessibilityHint("Shows or hides secondary session columns.")
    }
    ToolbarItem(placement: .principal) {
      SessionToolbarCenterpiece(
        metrics: connectionMetrics,
        source: sourcePresentation,
        statusStripState: statusStripState
      )
      .help("Current connection, source, session, and service status.")
      .accessibilityElement(children: .ignore)
      .accessibilityIdentifier(HarnessMonitorAccessibility.sessionWindowStatusMenu)
      .accessibilityLabel("Session status")
      .accessibilityValue(sessionStatusAccessibilityValue)
    }
    ToolbarItem(placement: .primaryAction) {
      SleepPreventionToolbarButton(
        store: store,
        presentation: sleepPreventionPresentation
      )
    }
  }

  private func toggleFocusMode() {
    let animation = SessionFocusModeMotionPolicy.animation(reduceMotion: reduceMotion)
    if let animation {
      withAnimation(animation) {
        focusMode.toggle()
      }
    } else {
      focusMode.toggle()
    }
  }
}

private struct SessionToolbarCenterpiece: View {
  let metrics: ConnectionMetrics
  let source: SessionToolbarCenterpieceSourcePresentation
  let statusStripState: SessionToolbarCenterpieceStatusStripState
  @ScaledMetric(relativeTo: .caption)
  private var centerpieceContentWidth: CGFloat = 280
  @ScaledMetric(relativeTo: .caption)
  private var centerpieceHorizontalPadding: CGFloat = 12

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.itemSpacing) {
      ConnectionToolbarBadge(metrics: metrics)
        .accessibilityHidden(true)
      Spacer(minLength: 0)
      SessionToolbarCenterpieceServiceStrip(
        source: source,
        statusStripState: statusStripState
      )
    }
    .padding(.vertical, HarnessMonitorTheme.itemSpacing)
    .padding(.horizontal, centerpieceHorizontalPadding)
    .frame(width: centerpieceContentWidth)
    .fixedSize(horizontal: true, vertical: false)
    .layoutPriority(1)
  }
}

private struct SessionToolbarCenterpieceSourcePresentation {
  let title: String
  let systemImage: String
  let tint: Color
}

private struct SessionToolbarCenterpieceServiceStrip: View {
  let source: SessionToolbarCenterpieceSourcePresentation
  let statusStripState: SessionToolbarCenterpieceStatusStripState
  @ScaledMetric(relativeTo: .caption)
  private var chromeHeight: CGFloat = 14

  var body: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
      if statusStripState.hasVisibleTokens {
        HStack(alignment: .center, spacing: 3) {
          if let bridge = statusStripState.bridge {
            SessionToolbarCenterpieceStatusWord(token: bridge)
          }
          if statusStripState.showsSeparator {
            Text(verbatim: "·")
              .font(.system(.caption2, design: .rounded, weight: .semibold))
              .foregroundStyle(HarnessMonitorTheme.disabledConnectionChrome)
              .accessibilityHidden(true)
          }
          if let mcp = statusStripState.mcp {
            SessionToolbarCenterpieceStatusWord(token: mcp)
          }
        }
      }
      Image(systemName: source.systemImage)
        .scaledFont(.system(.caption2, design: .rounded, weight: .semibold))
        .foregroundStyle(source.tint)
        .frame(minHeight: chromeHeight, alignment: .center)
        .accessibilityHidden(true)
    }
    .fixedSize(horizontal: true, vertical: false)
    .frame(minHeight: chromeHeight, alignment: .center)
    .accessibilityHidden(true)
  }
}

private struct SessionToolbarCenterpieceStatusWord: View {
  let token: SessionToolbarCenterpieceStatusToken
  @ScaledMetric(relativeTo: .caption)
  private var chromeHeight: CGFloat = 14

  var body: some View {
    Text(token.label)
      .font(.system(.caption2, design: .rounded, weight: .semibold))
      .foregroundStyle(token.tone.color)
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
      .frame(minHeight: chromeHeight, alignment: .center)
      .accessibilityHidden(true)
  }
}
