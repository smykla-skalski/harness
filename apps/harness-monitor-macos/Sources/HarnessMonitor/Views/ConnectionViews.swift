import HarnessMonitorKit
import SwiftUI

struct TransportBadge: View {
  let kind: TransportKind

  private var icon: String {
    kind == .webSocket ? "bolt.horizontal.fill" : "arrow.down.circle.fill"
  }

  private var label: String {
    kind == .webSocket ? "WebSocket" : "SSE"
  }

  private var tint: Color {
    kind == .webSocket ? MonitorTheme.success : MonitorTheme.caution
  }

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: icon)
        .font(.caption2.weight(.semibold))
      Text(label)
        .font(.system(.caption, design: .rounded, weight: .semibold))
    }
    .foregroundStyle(tint)
    .padding(.horizontal, 9)
    .padding(.vertical, 5)
    .background(MonitorTheme.surfaceHover, in: Capsule())
    .overlay(
      Capsule()
        .stroke(tint.opacity(0.2), lineWidth: 1)
    )
  }
}

struct LatencyBadge: View {
  let latencyMs: Int?

  private var quality: ConnectionQuality {
    ConnectionQuality(latencyMs: latencyMs)
  }

  private var tint: Color {
    switch quality {
    case .excellent, .good: MonitorTheme.success
    case .degraded: MonitorTheme.caution
    case .poor, .disconnected: MonitorTheme.danger
    }
  }

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: "timer")
        .font(.caption2.weight(.semibold))
      Text(latencyMs.map { "\($0)ms" } ?? "--ms")
        .font(.system(.caption, design: .rounded, weight: .semibold).monospacedDigit())
    }
    .foregroundStyle(tint)
    .padding(.horizontal, 9)
    .padding(.vertical, 5)
    .background(MonitorTheme.surfaceHover, in: Capsule())
    .overlay(
      Capsule()
        .stroke(tint.opacity(0.18), lineWidth: 1)
    )
  }
}

struct ActivityPulse: View {
  let isActive: Bool
  @State private var animates = false

  private var baseColor: Color {
    isActive ? MonitorTheme.success : MonitorTheme.sidebarMuted
  }

  var body: some View {
    ZStack {
      if isActive {
        Circle()
          .fill(baseColor.opacity(0.14))
          .frame(width: 16, height: 16)
          .scaleEffect(animates ? 1.25 : 0.92)
          .opacity(animates ? 1.0 : 0.72)
          .animation(
            .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
            value: animates
          )
      }
      Circle()
        .fill(baseColor)
        .frame(width: 7, height: 7)
        .overlay(
          Circle()
            .stroke(MonitorTheme.panel.opacity(0.9), lineWidth: 1)
        )
    }
    .frame(width: 16, height: 16)
    .onAppear { animates = isActive }
    .onChange(of: isActive) { _, active in
      animates = active
    }
  }
}

struct ConnectionStatusStrip: View {
  let metrics: ConnectionMetrics
  let isActive: Bool

  private var title: String {
    metrics.transportKind == .webSocket ? "Live transport" : "Fallback transport"
  }

  private var subtitle: String {
    metrics.transportKind == .webSocket
      ? "Persistent socket updates"
      : "Streaming over HTTP events"
  }

  var body: some View {
    HStack(spacing: 10) {
      ActivityPulse(isActive: isActive)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.system(.footnote, design: .rounded, weight: .semibold))
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 8)

      HStack(spacing: 8) {
        TransportBadge(kind: metrics.transportKind)
        LatencyBadge(latencyMs: metrics.latencyMs)
      }
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(MonitorTheme.surface)
        .overlay(
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(MonitorTheme.controlBorder, lineWidth: 1)
        )
    )
  }
}

struct ConnectionToolbarBadge: View {
  let metrics: ConnectionMetrics

  private var icon: String {
    metrics.transportKind == .webSocket
      ? "bolt.horizontal.fill"
      : "arrow.down.circle.fill"
  }

  private var qualityColor: Color {
    switch metrics.quality {
    case .excellent, .good: MonitorTheme.success
    case .degraded: MonitorTheme.caution
    case .poor, .disconnected: MonitorTheme.danger
    }
  }

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: icon)
        .font(.caption2)
        .foregroundStyle(qualityColor)
      Text(metrics.latencyMs.map { "\($0)ms" } ?? "--")
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
      Circle()
        .fill(qualityColor)
        .frame(width: 6, height: 6)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(MonitorTheme.surface, in: Capsule())
    .overlay(
      Capsule()
        .stroke(MonitorTheme.controlBorder, lineWidth: 1)
    )
    .accessibilityIdentifier(MonitorAccessibility.connectionBadge)
  }
}

struct ReconnectionProgressView: View {
  let attempt: Int
  let maxAttempts: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        ProgressView()
          .controlSize(.small)
        Text("Reconnecting")
          .font(.system(.footnote, design: .rounded, weight: .semibold))
        Spacer()
        Text("Attempt \(attempt)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      GeometryReader { proxy in
        Capsule()
          .fill(MonitorTheme.surface)
          .frame(height: 4)
          .overlay(alignment: .leading) {
            let progress = min(Double(attempt) / Double(maxAttempts), 1.0)
            Capsule()
              .fill(MonitorTheme.caution)
              .frame(width: proxy.size.width * progress, height: 4)
          }
      }
      .frame(height: 4)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(
      MonitorTheme.caution.opacity(0.08),
      in: RoundedRectangle(cornerRadius: 14)
    )
    .accessibilityIdentifier(MonitorAccessibility.reconnectionProgress)
  }
}

struct FallbackBanner: View {
  let reason: String?
  let onRetry: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      RoundedRectangle(cornerRadius: 999, style: .continuous)
        .fill(MonitorTheme.caution)
        .frame(width: 5)

      VStack(alignment: .leading, spacing: 2) {
        Text("Running in fallback mode")
          .font(.system(.footnote, design: .rounded, weight: .semibold))
        Text(reason ?? "WebSocket unavailable, using HTTP streaming")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      Button(action: onRetry) {
        Label("Retry", systemImage: "arrow.clockwise")
          .font(.system(.caption, design: .rounded, weight: .semibold))
          .padding(.horizontal, 9)
          .padding(.vertical, 6)
          .background(MonitorTheme.surfaceHover, in: Capsule())
      }
      .buttonStyle(.plain)
      .foregroundStyle(MonitorTheme.caution)
    }
    .padding(10)
    .background(
      MonitorTheme.surface,
      in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(MonitorTheme.controlBorder, lineWidth: 1)
    )
    .accessibilityIdentifier(MonitorAccessibility.fallbackBanner)
  }
}

struct SparklineView: View {
  let data: [Double]
  let tint: Color

  var body: some View {
    GeometryReader { proxy in
      if data.count > 1, let maxValue = data.max(), maxValue > 0 {
        let size = proxy.size
        let stepX = size.width / Double(data.count - 1)

        ZStack {
          Path { path in
            path.move(to: point(index: 0, stepX: stepX, size: size, maxValue: maxValue))
            for index in 1..<data.count {
              path.addLine(to: point(index: index, stepX: stepX, size: size, maxValue: maxValue))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.addLine(to: CGPoint(x: 0, y: size.height))
            path.closeSubpath()
          }
          .fill(
            LinearGradient(
              colors: [tint.opacity(0.15), .clear],
              startPoint: .top,
              endPoint: .bottom
            )
          )

          Path { path in
            path.move(to: point(index: 0, stepX: stepX, size: size, maxValue: maxValue))
            for index in 1..<data.count {
              path.addLine(to: point(index: index, stepX: stepX, size: size, maxValue: maxValue))
            }
          }
          .stroke(tint, lineWidth: 1.5)
        }
      }
    }
  }

  private func point(index: Int, stepX: Double, size: CGSize, maxValue: Double) -> CGPoint {
    CGPoint(
      x: Double(index) * stepX,
      y: size.height - (data[index] / maxValue) * size.height
    )
  }
}

private func previewConnectionMetrics() -> ConnectionMetrics {
  var metrics = ConnectionMetrics.initial
  metrics.transportKind = .webSocket
  metrics.latencyMs = 34
  metrics.averageLatencyMs = 38
  metrics.messagesReceived = 18
  metrics.messagesSent = 7
  metrics.messagesPerSecond = 3.2
  metrics.connectedSince = .now.addingTimeInterval(-320)
  metrics.lastMessageAt = .now.addingTimeInterval(-4)
  metrics.reconnectAttempt = 0
  metrics.reconnectCount = 0
  return metrics
}

#Preview("Transport badges") {
  HStack(spacing: 12) {
    TransportBadge(kind: .webSocket)
    TransportBadge(kind: .httpSSE)
    LatencyBadge(latencyMs: 24)
    LatencyBadge(latencyMs: 200)
    LatencyBadge(latencyMs: nil)
    ActivityPulse(isActive: true)
    ActivityPulse(isActive: false)
  }
  .padding()
}

#Preview("Connection status strip") {
  ConnectionStatusStrip(
    metrics: previewConnectionMetrics(),
    isActive: true
  )
  .padding()
}
