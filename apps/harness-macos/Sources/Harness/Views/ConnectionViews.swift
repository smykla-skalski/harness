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
    HStack(spacing: 4) {
      Image(systemName: icon)
        .font(.caption2.weight(.semibold))
      Text(kind.title)
        .font(.system(.caption, design: .rounded, weight: .semibold))
        .lineLimit(1)
        .fixedSize()
    }
    .foregroundStyle(tint)
    .harnessPillPadding()
    .harnessInfoPill(tint: tint)
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
      .harnessPillPadding()
      .harnessInfoPill(tint: tint)
  }
}

struct ActivityPulse: View {
  let isActive: Bool
  private let activeColor: Color
  private let inactiveColor: Color
  @ScaledMetric(relativeTo: .caption)
  private var outerSize: CGFloat = 16
  @ScaledMetric(relativeTo: .caption)
  private var innerSize: CGFloat = 7
  @State private var isPulsing = false
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  init(
    isActive: Bool,
    outerSize: CGFloat = 16,
    innerSize: CGFloat = 7,
    activeColor: Color = HarnessTheme.success,
    inactiveColor: Color = HarnessTheme.secondaryInk.opacity(0.55)
  ) {
    self.isActive = isActive
    self.activeColor = activeColor
    self.inactiveColor = inactiveColor
    _outerSize = ScaledMetric(wrappedValue: outerSize, relativeTo: .caption)
    _innerSize = ScaledMetric(wrappedValue: innerSize, relativeTo: .caption)
  }

  private var baseColor: Color {
    isActive ? activeColor : inactiveColor
  }

  var body: some View {
    ZStack {
      Circle()
        .fill(baseColor.opacity(isPulsing ? 0.22 : 0.14))
        .frame(width: outerSize, height: outerSize)
        .scaleEffect(reduceMotion ? 1.0 : (isPulsing ? 1.3 : 1.0))
        .animation(
          reduceMotion
            ? .easeOut(duration: 0.3)
            : isPulsing
              ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
              : .easeOut(duration: 0.3),
          value: isPulsing
        )
      Circle()
        .fill(baseColor)
        .frame(width: innerSize, height: innerSize)
        .overlay(
          Circle()
            .stroke(Color.primary.opacity(0.14), lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.3), value: isActive)
    }
    .frame(width: outerSize, height: outerSize)
    .onChange(of: isActive) { _, active in
      isPulsing = active
    }
    .onAppear {
      isPulsing = isActive
    }
  }
}

struct ConnectionToolbarBadge: View {
  let metrics: ConnectionMetrics

  private static let badgeFont = Font.system(.caption, design: .rounded, weight: .semibold)
    .monospacedDigit()

  private var transportLabel: String {
    metrics.transportKind.shortTitle
  }

  private var latencyLabel: String {
    metrics.latencyMs.map { "\($0)ms" } ?? "--ms"
  }

  private var accessibilityLabel: String {
    if let latency = metrics.latencyMs {
      return "Connection: \(metrics.transportKind.shortTitle), latency \(latency) milliseconds"
    }
    return "Connection: \(metrics.transportKind.title)"
  }

  private var qualityColor: Color {
    if metrics.connectedSince != nil, metrics.latencyMs == nil {
      return HarnessTheme.success
    }
    return metrics.quality.themeColor
  }

  var body: some View {
    ZStack {
      // Reserve the maximum badge width so live telemetry updates do not churn window constraints.
      HStack(spacing: 4) {
        Color.clear
          .frame(width: 14, height: 14)
        Text("SSE")
          .font(Self.badgeFont)
          .lineLimit(1)
          .fixedSize()
        Rectangle()
          .fill(.clear)
          .frame(width: 1, height: 12)
        Text("999ms")
          .font(Self.badgeFont)
          .lineLimit(1)
          .fixedSize()
      }
      .hidden()

      HStack(spacing: 4) {
        ActivityPulse(
          isActive: metrics.connectedSince != nil,
          outerSize: 14,
          innerSize: 6,
          activeColor: qualityColor
        )
          .accessibilityHidden(true)
        Text(transportLabel)
          .font(Self.badgeFont)
          .foregroundStyle(qualityColor)
          .lineLimit(1)
          .fixedSize()
        Rectangle()
          .fill(qualityColor.opacity(metrics.latencyMs == nil ? 0 : 0.35))
          .frame(width: 1, height: 12)
          .accessibilityHidden(true)
        Text(latencyLabel)
          .font(Self.badgeFont)
          .foregroundStyle(qualityColor)
          .lineLimit(1)
          .fixedSize()
          .opacity(metrics.latencyMs == nil ? 0 : 1)
      }
    }
    .harnessPillPadding()
    .accessibilityElement(children: .ignore)
    .accessibilityIdentifier(HarnessAccessibility.connectionBadge)
    .accessibilityLabel(accessibilityLabel)
  }
}

struct ReconnectionProgressView: View {
  let attempt: Int
  let maxAttempts: Int

  private var progress: Double {
    min(Double(attempt) / Double(max(maxAttempts, 1)), 1.0)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
      HStack(spacing: HarnessTheme.itemSpacing) {
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

#Preview("Transport badges") {
  HStack(spacing: HarnessTheme.sectionSpacing) {
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
