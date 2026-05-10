import HarnessMonitorKit
import SwiftUI

struct SessionStatusSummaryModel: Equatable {
  let metrics: ConnectionMetrics
  let sourceTitle: String
  let sourceSystemImage: String
  let sourceTint: SessionStatusSourceTint
  let statusStripState: SessionStatusStripState
  let connectionSummaryText: String
  let sessionStatusTitle: String

  fileprivate var sourcePresentation: SessionStatusSourcePresentation {
    .init(
      systemImage: sourceSystemImage,
      tint: sourceTint.color
    )
  }

  var accessibilityValue: String {
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

  var helpText: String {
    let base = "Current connection, source, session, and service status."
    guard !statusStripState.helpText.isEmpty else {
      return base
    }
    return [base, statusStripState.helpText].joined(separator: "\n")
  }
}

enum SessionStatusSourceTint: Equatable {
  case tertiary
  case success
  case caution
  case danger
  case disabledConnection

  var color: Color {
    switch self {
    case .tertiary:
      HarnessMonitorTheme.tertiaryInk
    case .success:
      HarnessMonitorTheme.success
    case .caution:
      HarnessMonitorTheme.caution
    case .danger:
      HarnessMonitorTheme.danger
    case .disabledConnection:
      HarnessMonitorTheme.disabledConnectionChrome
    }
  }
}

struct SessionSidebarFooter: View {
  let model: SessionStatusSummaryModel
  @ScaledMetric(relativeTo: .caption)
  private var horizontalPadding: CGFloat = 12
  @ScaledMetric(relativeTo: .caption)
  private var footerHorizontalPadding: CGFloat = 8
  @ScaledMetric(relativeTo: .caption)
  private var footerOuterPadding: CGFloat = 10

  var body: some View {
    SessionStatusSummary(
      metrics: model.metrics,
      source: model.sourcePresentation,
      statusStripState: model.statusStripState,
      usesFlexibleSpacer: true
    )
    .padding(.vertical, HarnessMonitorTheme.itemSpacing)
    .padding(.horizontal, horizontalPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .fill(HarnessMonitorTheme.ink.opacity(0.04))
    }
    .overlay {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .strokeBorder(HarnessMonitorTheme.controlBorder.opacity(0.32), lineWidth: 1)
    }
    .padding(.horizontal, footerHorizontalPadding)
    .padding(.top, HarnessMonitorTheme.spacingXS)
    .padding(.bottom, footerOuterPadding)
    .help(model.helpText)
    .accessibilityElement(children: .ignore)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sessionWindowStatusSurface)
    .accessibilityLabel("Session status")
    .accessibilityValue(model.accessibilityValue)
  }
}

struct SessionToolbarStatusFallback: View {
  let model: SessionStatusSummaryModel
  @ScaledMetric(relativeTo: .caption)
  private var horizontalPadding: CGFloat = 8

  var body: some View {
    SessionStatusSummary(
      metrics: model.metrics,
      source: model.sourcePresentation,
      statusStripState: model.statusStripState,
      usesFlexibleSpacer: false
    )
    .padding(.vertical, HarnessMonitorTheme.itemSpacing)
    .padding(.horizontal, horizontalPadding)
    .fixedSize(horizontal: true, vertical: false)
    .help(model.helpText)
    .accessibilityElement(children: .ignore)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sessionWindowStatusSurface)
    .accessibilityLabel("Session status")
    .accessibilityValue(model.accessibilityValue)
  }
}

private struct SessionStatusSummary: View {
  let metrics: ConnectionMetrics
  let source: SessionStatusSourcePresentation
  let statusStripState: SessionStatusStripState
  let usesFlexibleSpacer: Bool

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.itemSpacing) {
      SessionStatusSourceIcon(source: source)
      SessionStatusTransportChrome(metrics: metrics)
      if usesFlexibleSpacer {
        Spacer(minLength: 0)
      }
      SessionStatusStrip(statusStripState: statusStripState)
    }
  }
}

private struct SessionStatusSourcePresentation {
  let systemImage: String
  let tint: Color
}

private struct SessionStatusStrip: View {
  let statusStripState: SessionStatusStripState
  @ScaledMetric(relativeTo: .caption)
  private var chromeHeight: CGFloat = 14

  var body: some View {
    HStack(alignment: .center, spacing: 3) {
      if let bridge = statusStripState.bridge {
        SessionStatusWord(token: bridge)
      }
      if statusStripState.showsSeparator {
        SessionStatusSeparator()
      }
      if let mcp = statusStripState.mcp {
        SessionStatusWord(token: mcp)
      }
    }
    .fixedSize(horizontal: true, vertical: false)
    .frame(minHeight: chromeHeight, alignment: .center)
    .accessibilityHidden(true)
  }
}

private struct SessionStatusTransportChrome: View {
  let metrics: ConnectionMetrics

  private static let badgeFont = Font.system(.caption2, design: .rounded, weight: .semibold)
    .monospacedDigit()
  @ScaledMetric(relativeTo: .caption2)
  private var transportLabelWidth: CGFloat = 24
  @ScaledMetric(relativeTo: .caption2)
  private var latencyLabelWidth: CGFloat = 34
  @ScaledMetric(relativeTo: .caption)
  private var chromeHeight: CGFloat = 14

  private var showsConnectionDetails: Bool {
    metrics.connectedSince != nil
  }

  private var showsLatencyValue: Bool {
    showsConnectionDetails && metrics.transportLatencyMs != nil
  }

  private var transportLabel: String {
    metrics.transportKind.shortTitle
  }

  private var latencyLabel: String {
    guard let latencyMs = metrics.transportLatencyMs else {
      return "--ms"
    }
    if latencyMs >= 1_000 {
      return "999+"
    }
    return "\(latencyMs)ms"
  }

  private var statusTint: Color {
    metrics.latencyTint
  }

  var body: some View {
    HStack(alignment: .center, spacing: 1) {
      Text(transportLabel)
        .font(Self.badgeFont)
        .foregroundStyle(statusTint)
        .lineLimit(1)
        .frame(minWidth: transportLabelWidth, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .opacity(showsConnectionDetails ? 1 : 0)
        .accessibilityHidden(!showsConnectionDetails)
      Text(latencyLabel)
        .font(Self.badgeFont)
        .foregroundStyle(statusTint.opacity(0.5))
        .lineLimit(1)
        .frame(minWidth: latencyLabelWidth, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .opacity(showsLatencyValue ? 1 : 0)
        .accessibilityHidden(!showsLatencyValue)
    }
    .fixedSize(horizontal: true, vertical: false)
    .frame(minHeight: chromeHeight, alignment: .center)
    .accessibilityHidden(true)
  }
}

private struct SessionStatusSeparator: View {
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

private struct SessionStatusSourceIcon: View {
  let source: SessionStatusSourcePresentation
  @ScaledMetric(relativeTo: .caption)
  private var chromeHeight: CGFloat = 14

  var body: some View {
    Image(systemName: source.systemImage)
      .font(.system(.caption2, design: .rounded, weight: .semibold))
      .foregroundStyle(source.tint)
      .frame(minHeight: chromeHeight, alignment: .center)
      .accessibilityHidden(true)
  }
}

private struct SessionStatusWord: View {
  let token: SessionStatusToken
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
