import HarnessKit
import SwiftUI

struct TransportBadge: View {
  let kind: TransportKind

  private var icon: String {
    kind == .webSocket ? "bolt.horizontal.fill" : "arrow.down.circle.fill"
  }

  private var tint: Color {
    kind == .webSocket ? HarnessTheme.success : HarnessTheme.caution
  }

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: icon)
        .font(.caption2.weight(.semibold))
      Text(kind.title)
        .font(.system(.caption, design: .rounded, weight: .semibold))
        .lineLimit(1)
        .fixedSize()
    }
    .foregroundStyle(tint)
    .padding(.horizontal, 9)
    .padding(.vertical, 5)
    .harnessCapsuleGlass()
    .fixedSize()
    .accessibilityElement(children: .combine)
  }
}

struct LatencyBadge: View {
  let latencyMs: Int?

  private var quality: ConnectionQuality {
    ConnectionQuality(latencyMs: latencyMs)
  }

  private var tint: Color {
    quality.themeColor
  }

  var body: some View {
    Text(latencyMs.map { "\($0)ms" } ?? "n/a")
      .font(.system(.caption, design: .rounded, weight: .semibold).monospacedDigit())
      .foregroundStyle(tint)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 9)
      .padding(.vertical, 5)
      .harnessCapsuleGlass()
  }
}

struct ActivityPulse: View {
  let isActive: Bool
  @State private var isPulsing = false

  private var baseColor: Color {
    isActive ? HarnessTheme.success : HarnessTheme.secondaryInk.opacity(0.55)
  }

  var body: some View {
    ZStack {
      Circle()
        .fill(baseColor.opacity(isPulsing ? 0.22 : 0.14))
        .frame(width: 16, height: 16)
        .scaleEffect(isPulsing ? 1.3 : 1.0)
        .animation(
          isPulsing
            ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
            : .easeOut(duration: 0.3),
          value: isPulsing
        )
      Circle()
        .fill(baseColor)
        .frame(width: 7, height: 7)
        .overlay(
          Circle()
            .stroke(Color.primary.opacity(0.14), lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.3), value: isActive)
    }
    .frame(width: 16, height: 16)
    .onChange(of: isActive) { _, active in
      isPulsing = active
    }
    .onAppear {
      isPulsing = isActive
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
          .foregroundStyle(HarnessTheme.secondaryInk)
      }

      Spacer(minLength: 8)

      HarnessGlassContainer(spacing: 8) {
        HStack(spacing: 8) {
          TransportBadge(kind: metrics.transportKind)
          LatencyBadge(latencyMs: metrics.latencyMs)
        }
      }
    }
  }
}

struct ConnectionToolbarBadge: View {
  let metrics: ConnectionMetrics

  private var label: String {
    if let latency = metrics.latencyMs {
      return "\(metrics.transportKind.shortTitle) \(latency)ms"
    }
    return metrics.transportKind.title
  }

  private var qualityColor: Color {
    if metrics.connectedSince != nil, metrics.latencyMs == nil {
      return HarnessTheme.success
    }
    return metrics.quality.themeColor
  }

  var body: some View {
    HStack(spacing: 5) {
      Circle()
        .fill(qualityColor)
        .frame(width: 6, height: 6)
        .accessibilityHidden(true)
      Text(label)
        .font(.system(.caption, design: .rounded, weight: .semibold).monospacedDigit())
        .foregroundStyle(qualityColor)
        .lineLimit(1)
        .fixedSize()
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .fixedSize()
    .accessibilityIdentifier(HarnessAccessibility.connectionBadge)
    .accessibilityLabel("Connection: \(label)")
  }
}

struct ReconnectionProgressView: View {
  let attempt: Int
  let maxAttempts: Int

  private var progress: Double {
    min(Double(attempt) / Double(max(maxAttempts, 1)), 1.0)
  }

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
          .foregroundStyle(HarnessTheme.secondaryInk)
          .contentTransition(.numericText())
      }
      Capsule()
        .fill(Color.primary.opacity(0.10))
        .frame(height: 4)
        .overlay(alignment: .leading) {
          Capsule()
            .fill(HarnessTheme.caution)
            .frame(height: 4)
            .scaleEffect(x: progress, anchor: .leading)
            .animation(.spring(duration: 0.4), value: progress)
        }
        .clipShape(Capsule())
    }
    .animation(.spring(duration: 0.3), value: attempt)
    .accessibilityIdentifier(HarnessAccessibility.reconnectionProgress)
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

extension ConnectionQuality {
  var themeColor: Color {
    switch self {
    case .excellent, .good:
      HarnessTheme.success
    case .degraded:
      HarnessTheme.caution
    case .poor, .disconnected:
      HarnessTheme.danger
    }
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
