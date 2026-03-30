import HarnessKit
import SwiftUI

struct PreferencesConnectionCard: View {
  let metrics: ConnectionMetrics
  let events: [ConnectionEvent]

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Connection")
        .font(.system(.title3, weight: .semibold))

      HarnessGlassContainer(spacing: 14) {
        HarnessAdaptiveGridLayout(minimumColumnWidth: 140, maximumColumns: 4, spacing: 14) {
          connectionMetric("Transport", value: metrics.transportKind.title, tint: qualityColor)
          connectionMetric("Latency", value: latencyText, tint: qualityColor)
          connectionMetric(
            "Messages in", value: "\(metrics.messagesReceived)", tint: HarnessTheme.accent
          )
          connectionMetric(
            "Messages out", value: "\(metrics.messagesSent)", tint: HarnessTheme.warmAccent
          )
          connectionMetric("Uptime", value: uptimeText, tint: HarnessTheme.success)
          connectionMetric("Reconnects", value: "\(metrics.reconnectCount)", tint: reconnectTint)
          connectionMetric("Msg/sec", value: rateText, tint: HarnessTheme.accent)
          connectionMetric("Quality", value: metrics.quality.title, tint: qualityColor)
        }
      }

      if !events.isEmpty {
        connectionEventLog
      }
    }
    .harnessCard()
    .accessibilityIdentifier(HarnessAccessibility.connectionCard)
  }

  private var qualityColor: Color {
    switch metrics.quality {
    case .excellent, .good: HarnessTheme.success
    case .degraded: HarnessTheme.caution
    case .poor, .disconnected: HarnessTheme.danger
    }
  }

  private var reconnectTint: Color {
    metrics.reconnectCount > 0 ? HarnessTheme.caution : HarnessTheme.success
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
        .foregroundStyle(HarnessTheme.secondaryInk)
      Text(value)
        .font(.system(.headline, weight: .semibold))
        .foregroundStyle(tint)
        .contentTransition(.numericText())
    }
    .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
    .padding(12)
    .background {
      HarnessInsetPanelBackground(
        cornerRadius: 18,
        fillOpacity: 0.05,
        strokeOpacity: 0.10
      )
    }
  }

  private var connectionEventLog: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Recent events")
        .font(.system(.headline, weight: .semibold))

      HarnessGlassContainer(spacing: 8) {
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
              .foregroundStyle(HarnessTheme.secondaryInk)
          }
          .padding(10)
          .background {
            HarnessInsetPanelBackground(
              cornerRadius: 14,
              fillOpacity: 0.05,
              strokeOpacity: 0.10
            )
          }
        }
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
    case .connected: HarnessTheme.success
    case .disconnected: HarnessTheme.danger
    case .reconnecting: HarnessTheme.caution
    case .fallback: HarnessTheme.caution
    case .error: HarnessTheme.danger
    }
  }

  private func formatTimestamp(_ date: Date) -> String {
    nonisolated(unsafe) let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
  }
}
