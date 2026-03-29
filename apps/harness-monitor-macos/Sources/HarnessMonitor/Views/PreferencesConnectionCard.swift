import HarnessMonitorKit
import SwiftUI

struct PreferencesConnectionCard: View {
  let metrics: ConnectionMetrics
  let events: [ConnectionEvent]

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Connection")
        .font(.system(.title3, design: .serif, weight: .semibold))

      MonitorAdaptiveGridLayout(minimumColumnWidth: 140, maximumColumns: 4, spacing: 14) {
        connectionMetric("Transport", value: metrics.transportKind.rawValue, tint: qualityColor)
        connectionMetric("Latency", value: latencyText, tint: qualityColor)
        connectionMetric(
          "Messages in", value: "\(metrics.messagesReceived)", tint: MonitorTheme.accent
        )
        connectionMetric(
          "Messages out", value: "\(metrics.messagesSent)", tint: MonitorTheme.warmAccent
        )
        connectionMetric("Uptime", value: uptimeText, tint: MonitorTheme.success)
        connectionMetric("Reconnects", value: "\(metrics.reconnectCount)", tint: reconnectTint)
        connectionMetric("Msg/sec", value: rateText, tint: MonitorTheme.accent)
        connectionMetric("Quality", value: metrics.quality.rawValue, tint: qualityColor)
      }

      if !events.isEmpty {
        connectionEventLog
      }
    }
    .monitorCard()
    .accessibilityIdentifier(MonitorAccessibility.connectionCard)
  }

  private var qualityColor: Color {
    switch metrics.quality {
    case .excellent, .good: MonitorTheme.success
    case .degraded: MonitorTheme.caution
    case .poor, .disconnected: MonitorTheme.danger
    }
  }

  private var reconnectTint: Color {
    metrics.reconnectCount > 0 ? MonitorTheme.caution : MonitorTheme.success
  }

  private var latencyText: String {
    metrics.latencyMs.map { "\($0)ms" } ?? "--"
  }

  private var uptimeText: String {
    guard let since = metrics.connectedSince else { return "--" }
    let seconds = Int(Date().timeIntervalSince(since))
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
  }

  private var rateText: String {
    String(format: "%.1f", metrics.messagesPerSecond)
  }

  private func connectionMetric(
    _ title: String,
    value: String,
    tint: Color
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title.uppercased())
        .font(.caption2.weight(.bold))
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(.headline, design: .rounded, weight: .semibold))
        .foregroundStyle(tint)
        .contentTransition(.numericText())
    }
    .monitorCard(minHeight: 72, contentPadding: 12)
  }

  private var connectionEventLog: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Recent events")
        .font(.system(.headline, design: .rounded, weight: .semibold))

      ForEach(events.suffix(10)) { event in
        HStack(spacing: 8) {
          Image(systemName: eventIcon(for: event.kind))
            .foregroundStyle(eventColor(for: event.kind))
            .font(.caption)
            .frame(width: 16)
          Text(event.detail)
            .font(.system(.body, design: .rounded, weight: .medium))
            .lineLimit(1)
          Spacer()
          Text(formatTimestamp(event.timestamp))
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(MonitorTheme.surface, in: RoundedRectangle(cornerRadius: 14))
      }
    }
  }

  private func eventIcon(for kind: ConnectionEventKind) -> String {
    switch kind {
    case .connected: "checkmark.circle.fill"
    case .disconnected: "xmark.circle.fill"
    case .reconnecting: "arrow.clockwise"
    case .fallback: "exclamationmark.triangle.fill"
    case .error: "exclamationmark.octagon.fill"
    }
  }

  private func eventColor(for kind: ConnectionEventKind) -> Color {
    switch kind {
    case .connected: MonitorTheme.success
    case .disconnected: MonitorTheme.danger
    case .reconnecting: MonitorTheme.caution
    case .fallback: MonitorTheme.caution
    case .error: MonitorTheme.danger
    }
  }

  private func formatTimestamp(_ date: Date) -> String {
    nonisolated(unsafe) let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
  }
}
