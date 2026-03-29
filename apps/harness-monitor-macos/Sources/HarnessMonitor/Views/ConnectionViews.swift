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
    HStack(spacing: 4) {
      Image(systemName: icon)
        .font(.caption2)
      Text(label)
        .font(.caption.bold())
    }
    .foregroundStyle(.white)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(tint, in: Capsule())
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
    Text(latencyMs.map { "\($0)ms" } ?? "--ms")
      .font(.caption.bold().monospacedDigit())
      .foregroundStyle(tint)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(tint.opacity(0.15), in: Capsule())
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
          .stroke(baseColor.opacity(0.4), lineWidth: 1)
          .frame(width: 20, height: 20)
          .scaleEffect(animates ? 1.8 : 1.0)
          .opacity(animates ? 0.0 : 0.6)
          .animation(
            .easeOut(duration: 1.2).repeatForever(autoreverses: false),
            value: animates
          )
      }
      Circle()
        .fill(baseColor)
        .frame(width: 10, height: 10)
    }
    .frame(width: 20, height: 20)
    .onAppear { animates = isActive }
    .onChange(of: isActive) { _, active in
      animates = active
    }
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
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(MonitorTheme.surfaceHover, in: Capsule())
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
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(MonitorTheme.caution)
      VStack(alignment: .leading, spacing: 2) {
        Text("Running in fallback mode")
          .font(.system(.footnote, design: .rounded, weight: .semibold))
        Text(reason ?? "WebSocket unavailable, using HTTP streaming")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("Retry", action: onRetry)
        .font(.caption.bold())
        .buttonStyle(.bordered)
    }
    .padding(10)
    .background(
      MonitorTheme.caution.opacity(0.08),
      in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(MonitorTheme.caution.opacity(0.2), lineWidth: 1)
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
