import HarnessMonitorKit
import SwiftUI

struct SessionWindowToolbarModel: Equatable {
  let canNavigateBack: Bool
  let canNavigateForward: Bool
  let sleepPreventionPresentation: SleepPreventionToolbarPresentation
  let connectionMetrics: ConnectionMetrics
  let sourceTitle: String
  let sourceSystemImage: String
  let sourceTint: SessionToolbarSourceTint
  let statusStripState: SessionToolbarCenterpieceStatusStripState
  let connectionSummaryText: String
  let sessionStatusTitle: String

  fileprivate var sourcePresentation: SessionToolbarCenterpieceSourcePresentation {
    .init(
      title: sourceTitle,
      systemImage: sourceSystemImage,
      tint: sourceTint.color
    )
  }

  var sessionStatusAccessibilityValue: String {
    var parts = [
      connectionSummaryText,
      "Source: \(sourceTitle)",
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
}

enum SessionToolbarSourceTint: Equatable {
  case tertiary
  case success
  case disabledConnection

  var color: Color {
    switch self {
    case .tertiary:
      HarnessMonitorTheme.tertiaryInk
    case .success:
      HarnessMonitorTheme.success
    case .disabledConnection:
      HarnessMonitorTheme.disabledConnectionChrome
    }
  }
}

struct SessionWindowToolbar: ToolbarContent {
  let store: HarnessMonitorStore
  let model: SessionWindowToolbarModel
  let state: SessionWindowStateCache
  @Binding var focusMode: Bool
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .navigation) {
      Button {
        state.navigateBack()
      } label: {
        Label {
          Text("Go back")
        } icon: {
          Image(systemName: "chevron.backward")
            .frame(width: 14, height: 14)
        }
      }
      .disabled(!state.navigationHistory.canGoBack)
      .help("Go back")
      .accessibilityLabel("Back")
      .accessibilityIdentifier(HarnessMonitorAccessibility.sessionNavigateBackButton)

      Button {
        state.navigateForward()
      } label: {
        Label {
          Text("Go forward")
        } icon: {
          Image(systemName: "chevron.forward")
            .frame(width: 14, height: 14)
        }
      }
      .disabled(!state.navigationHistory.canGoForward)
      .help("Go forward")
      .accessibilityLabel("Forward")
      .accessibilityIdentifier(HarnessMonitorAccessibility.sessionNavigateForwardButton)
    }
    ToolbarItem(placement: .automatic) {
      Button {
        toggleFocusMode()
      } label: {
        Label {
          Text(focusMode ? "Exit focus mode" : "Enter focus mode")
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
        metrics: model.connectionMetrics,
        source: model.sourcePresentation,
        statusStripState: model.statusStripState
      )
      .help("Current connection, source, session, and service status.")
      .accessibilityElement(children: .ignore)
      .accessibilityIdentifier(HarnessMonitorAccessibility.sessionWindowStatusMenu)
      .accessibilityLabel("Session status")
      .accessibilityValue(model.sessionStatusAccessibilityValue)
    }
    ToolbarItem(placement: .primaryAction) {
      SleepPreventionToolbarButton(
        store: store,
        presentation: model.sleepPreventionPresentation
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
      SessionToolbarCenterpieceSourceIcon(source: source)
      Spacer(minLength: 0)
      SessionToolbarCenterpieceStatusStrip(
        statusStripState: statusStripState,
        metrics: metrics
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

private struct SessionToolbarCenterpieceStatusStrip: View {
  let statusStripState: SessionToolbarCenterpieceStatusStripState
  let metrics: ConnectionMetrics
  @ScaledMetric(relativeTo: .caption)
  private var chromeHeight: CGFloat = 14

  var body: some View {
    HStack(alignment: .center, spacing: 3) {
      if let bridge = statusStripState.bridge {
        SessionToolbarCenterpieceStatusWord(token: bridge)
      }
      if statusStripState.showsSeparator {
        SessionToolbarCenterpieceSeparator()
      }
      if let mcp = statusStripState.mcp {
        SessionToolbarCenterpieceStatusWord(token: mcp)
      }
      if statusStripState.hasVisibleTokens {
        SessionToolbarCenterpieceSeparator()
      }
      ConnectionToolbarBadge(metrics: metrics)
        .accessibilityHidden(true)
    }
    .fixedSize(horizontal: true, vertical: false)
    .frame(minHeight: chromeHeight, alignment: .center)
    .accessibilityHidden(true)
  }
}

private struct SessionToolbarCenterpieceSeparator: View {
  @ScaledMetric(relativeTo: .caption)
  private var chromeHeight: CGFloat = 14

  var body: some View {
    Text(verbatim: "·")
      .font(.system(.caption2, design: .rounded, weight: .semibold))
      .foregroundStyle(HarnessMonitorTheme.disabledConnectionChrome)
      .frame(minHeight: chromeHeight, alignment: .center)
      .accessibilityHidden(true)
  }
}

private struct SessionToolbarCenterpieceSourceIcon: View {
  let source: SessionToolbarCenterpieceSourcePresentation
  @ScaledMetric(relativeTo: .caption)
  private var chromeHeight: CGFloat = 14

  var body: some View {
    Image(systemName: source.systemImage)
      .scaledFont(.system(.caption2, design: .rounded, weight: .semibold))
      .foregroundStyle(source.tint)
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
