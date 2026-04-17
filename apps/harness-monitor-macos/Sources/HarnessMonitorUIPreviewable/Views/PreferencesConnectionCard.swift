import HarnessMonitorKit
import SwiftUI

private func formatConnectionUptime(since: Date?, now: Date) -> String {
  guard let since else { return "--" }
  let seconds = Int(now.timeIntervalSince(since))
  if seconds < 60 { return "\(seconds)s" }
  if seconds < 3600 { return "\(seconds / 60)m" }
  return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
}

private func connectionEventIcon(for kind: ConnectionEventKind) -> String {
  switch kind {
  case .connected: "checkmark.circle.fill"
  case .disconnected: "xmark.circle.fill"
  case .reconnecting: "arrow.clockwise"
  case .fallback: "exclamationmark.triangle.fill"
  case .error: "exclamationmark.octagon.fill"
  case .info: "info.circle.fill"
  }
}

private func connectionEventColor(for kind: ConnectionEventKind) -> Color {
  switch kind {
  case .connected: HarnessMonitorTheme.success
  case .disconnected: HarnessMonitorTheme.danger
  case .reconnecting: HarnessMonitorTheme.caution
  case .fallback: HarnessMonitorTheme.caution
  case .error: HarnessMonitorTheme.danger
  case .info: HarnessMonitorTheme.secondaryInk
  }
}

struct PreferencesConnectionMetrics: View {
  let metrics: ConnectionMetrics
  let events: [ConnectionEvent]

  var body: some View {
    PreferencesConnectionMetricsSection(metrics: metrics)

    if !events.isEmpty {
      PreferencesConnectionRecentEventsSection(events: events)
    }
  }
}

private struct PreferencesConnectionMetricsSection: View {
  let metrics: ConnectionMetrics

  private var latencyText: String {
    metrics.latencyMs.map { "\($0)ms" } ?? "--"
  }

  private var rateText: String {
    metrics.messagesPerSecond.formatted(
      .number.precision(.fractionLength(1))
    )
  }

  private var reconnectTint: Color {
    metrics.reconnectCount > 0 ? HarnessMonitorTheme.caution : HarnessMonitorTheme.success
  }

  var body: some View {
    Section("Metrics") {
      LabeledContent("Transport", value: metrics.transportKind.title)
      LabeledContent("Latency", value: latencyText)
      LabeledContent("Messages In", value: "\(metrics.messagesReceived)")
      LabeledContent("Messages Out", value: "\(metrics.messagesSent)")
      LabeledContent("Uptime") {
        PreferencesConnectionUptimeValue(connectedSince: metrics.connectedSince)
      }
      LabeledContent("Reconnects") {
        Text("\(metrics.reconnectCount)")
          .foregroundStyle(reconnectTint)
      }
      LabeledContent("Msg/sec", value: rateText)
      LabeledContent("Quality", value: metrics.quality.title)
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.connectionCard)
  }
}

private struct PreferencesConnectionRecentEventsSection: View {
  let events: [ConnectionEvent]
  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration

  var body: some View {
    Section("Recent Events") {
      ForEach(events.suffix(10)) { event in
        HStack(spacing: HarnessMonitorTheme.itemSpacing) {
          Image(systemName: connectionEventIcon(for: event.kind))
            .foregroundStyle(connectionEventColor(for: event.kind))
            .scaledFont(.caption)
            .frame(width: 16)
            .accessibilityHidden(true)
          Text(event.detail)
            .lineLimit(1)
          Spacer()
          Text(formatTimestamp(event.timestamp, configuration: dateTimeConfiguration))
            .scaledFont(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
      }
    }
  }
}

private struct PreferencesConnectionUptimeValue: View {
  let connectedSince: Date?

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      Text(formatConnectionUptime(since: connectedSince, now: context.date))
    }
  }
}

#Preview("Preferences Connection Metrics") {
  let store = PreferencesPreviewSupport.makeStore()

  Form {
    PreferencesConnectionMetrics(
      metrics: store.connectionMetrics,
      events: store.connectionEvents
    )
  }
  .preferencesDetailFormStyle()
  .frame(width: 560)
}
