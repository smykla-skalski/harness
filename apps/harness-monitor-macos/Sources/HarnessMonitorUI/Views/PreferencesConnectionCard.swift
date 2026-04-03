import HarnessMonitorKit
import SwiftUI

struct PreferencesConnectionMetrics: View {
  let metrics: ConnectionMetrics
  let events: [ConnectionEvent]

  private var latencyText: String {
    metrics.latencyMs.map { "\($0)ms" } ?? "--"
  }
  private static func formatUptime(since: Date?, now: Date) -> String {
    guard let since else { return "--" }
    let seconds = Int(now.timeIntervalSince(since))
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
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
      LabeledContent(
        "Transport", value: metrics.transportKind.title
      )
      LabeledContent("Latency", value: latencyText)
      LabeledContent(
        "Messages In", value: "\(metrics.messagesReceived)"
      )
      LabeledContent(
        "Messages Out", value: "\(metrics.messagesSent)"
      )
      LabeledContent("Uptime") {
        TimelineView(.periodic(from: .now, by: 1)) { context in
          Text(Self.formatUptime(since: metrics.connectedSince, now: context.date))
        }
      }
      LabeledContent("Reconnects") {
        Text("\(metrics.reconnectCount)")
          .foregroundStyle(reconnectTint)
      }
      LabeledContent("Msg/sec", value: rateText)
      LabeledContent("Quality", value: metrics.quality.title)
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.connectionCard)

    if !events.isEmpty {
      Section("Recent Events") {
        ForEach(events.suffix(10)) { event in
          HStack(spacing: HarnessMonitorTheme.itemSpacing) {
            Image(systemName: eventIcon(for: event.kind))
              .foregroundStyle(eventColor(for: event.kind))
              .scaledFont(.caption)
              .frame(width: 16)
              .accessibilityHidden(true)
            Text(event.detail)
              .lineLimit(1)
            Spacer()
            Text(formatTimestamp(event.timestamp))
              .scaledFont(.caption.monospaced())
              .foregroundStyle(.secondary)
          }
          .accessibilityElement(children: .combine)
        }
      }
    }
  }

  private func eventIcon(
    for kind: ConnectionEventKind
  ) -> String {
    switch kind {
    case .connected: "checkmark.circle.fill"
    case .disconnected: "xmark.circle.fill"
    case .reconnecting: "arrow.clockwise"
    case .fallback: "exclamationmark.triangle.fill"
    case .error: "exclamationmark.octagon.fill"
    }
  }

  private func eventColor(
    for kind: ConnectionEventKind
  ) -> Color {
    switch kind {
    case .connected: HarnessMonitorTheme.success
    case .disconnected: HarnessMonitorTheme.danger
    case .reconnecting: HarnessMonitorTheme.caution
    case .fallback: HarnessMonitorTheme.caution
    case .error: HarnessMonitorTheme.danger
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
