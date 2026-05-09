import HarnessMonitorKit
import SwiftUI

struct TransportBadge: View {
  let kind: TransportKind

  private var icon: String {
    kind == .webSocket ? "bolt.horizontal.fill" : "arrow.down.circle.fill"
  }

  private var tint: Color {
    kind == .webSocket ? HarnessMonitorTheme.success : HarnessMonitorTheme.caution
  }

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: icon)
        .scaledFont(.caption2.weight(.semibold))
      Text(kind.title)
        .scaledFont(.system(.caption, design: .rounded, weight: .semibold))
        .lineLimit(1)
        .fixedSize()
    }
    .foregroundStyle(tint)
    .harnessPillPadding()
    .harnessControlPill(tint: tint)
    .harnessUITestValue("chrome=glass-static")
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

  private var accessibilityLabel: String {
    if let latencyMs {
      return "Network latency \(latencyMs) milliseconds, \(quality.accessibilityDescription)"
    }
    return "Network latency unavailable"
  }

  var body: some View {
    Text(latencyMs.map { "\($0)ms" } ?? "n/a")
      .scaledFont(.system(.caption, design: .rounded, weight: .semibold).monospacedDigit())
      .foregroundStyle(tint)
      .lineLimit(1)
      .fixedSize()
      .harnessPillPadding()
      .harnessControlPill(tint: tint)
      .harnessUITestValue("chrome=glass-static")
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(accessibilityLabel)
  }
}

struct ActivityPulse: View {
  let isActive: Bool
  private let activeColor: Color
  private let inactiveColor: Color
  @ScaledMetric(relativeTo: .caption2)
  private var outerSize: CGFloat = 16
  @ScaledMetric(relativeTo: .caption2)
  private var innerSize: CGFloat = 7
  @State private var isPulsing = false
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  init(
    isActive: Bool,
    outerSize: CGFloat = 16,
    innerSize: CGFloat = 7,
    activeColor: Color = HarnessMonitorTheme.success,
    inactiveColor: Color = HarnessMonitorTheme.disabledConnectionChrome
  ) {
    self.isActive = isActive
    self.activeColor = activeColor
    self.inactiveColor = inactiveColor
    _outerSize = ScaledMetric(wrappedValue: outerSize, relativeTo: .caption2)
    _innerSize = ScaledMetric(wrappedValue: innerSize, relativeTo: .caption2)
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

  private static let badgeFont = Font.system(.caption2, design: .rounded, weight: .semibold)
  @ScaledMetric(relativeTo: .caption2)
  private var transportLabelWidth: CGFloat = 24

  private var showsConnectionDetails: Bool {
    metrics.connectedSince != nil
  }

  private var transportLabel: String {
    metrics.transportKind.shortTitle
  }

  private var accessibilityLabel: String {
    guard showsConnectionDetails else {
      return "Connection unavailable"
    }
    return "Connection: \(metrics.transportKind.title)"
  }

  private var statusTint: Color {
    if showsConnectionDetails, metrics.latencyMs == nil {
      return HarnessMonitorTheme.success
    }
    return metrics.latencyTint
  }

  private var profilingAttributes: [String: String] {
    [
      "harness.view.transport": metrics.transportKind.rawValue,
      "harness.view.has_connection_details": showsConnectionDetails ? "true" : "false",
    ]
  }

  var body: some View {
    ViewBodySignposter.trace(
      Self.self,
      "ConnectionToolbarBadge",
      attributes: profilingAttributes
    ) {
      HStack(spacing: 2) {
        Text(transportLabel)
          .font(Self.badgeFont)
          .foregroundStyle(statusTint)
          .lineLimit(1)
          .frame(minWidth: transportLabelWidth, alignment: .leading)
          .fixedSize(horizontal: true, vertical: false)
          .opacity(showsConnectionDetails ? 1 : 0)
          .accessibilityHidden(!showsConnectionDetails)
        ActivityPulse(
          isActive: showsConnectionDetails,
          outerSize: 14,
          innerSize: 6,
          activeColor: statusTint
        )
        .accessibilityHidden(true)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityIdentifier(HarnessMonitorAccessibility.connectionBadge)
      .accessibilityLabel(accessibilityLabel)
      .harnessUITestValue("chrome=glass-static")
      .help(accessibilityLabel)
    }
  }
}

struct ReconnectionProgressView: View {
  let attempt: Int
  let maxAttempts: Int

  private var progress: Double {
    min(Double(attempt) / Double(max(maxAttempts, 1)), 1.0)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      HStack(spacing: HarnessMonitorTheme.itemSpacing) {
        ProgressView()
          .controlSize(.small)
        Text("Reconnecting")
          .scaledFont(.system(.footnote, design: .rounded, weight: .semibold))
        Spacer()
        Text("Attempt \(attempt)")
          .scaledFont(.caption.monospacedDigit())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .contentTransition(.numericText())
      }
      Capsule()
        .fill(Color.primary.opacity(0.10))
        .frame(height: 4)
        .overlay(alignment: .leading) {
          Capsule()
            .fill(HarnessMonitorTheme.caution)
            .frame(height: 4)
            .scaleEffect(x: progress, anchor: .leading)
            .animation(.spring(duration: 0.4), value: progress)
        }
        .clipShape(Capsule())
    }
    .animation(.spring(duration: 0.3), value: attempt)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Reconnecting to daemon")
    .accessibilityValue("Attempt \(attempt) of \(maxAttempts)")
    .accessibilityIdentifier(HarnessMonitorAccessibility.reconnectionProgress)
  }
}

struct SparklineView: View {
  let tint: Color
  private let series: SparklineSeries?

  init(data: [Double], tint: Color) {
    self.tint = tint
    series = SparklineSeries(data: data)
  }

  var body: some View {
    GeometryReader { proxy in
      if let series {
        let geometry = SparklineGeometry(sampleCount: series.sampleCount, size: proxy.size)

        ZStack {
          series.areaPath(in: geometry)
            .fill(
              LinearGradient(
                colors: [tint.opacity(0.15), .clear],
                startPoint: .top,
                endPoint: .bottom
              )
            )

          series.linePath(in: geometry)
            .stroke(tint, lineWidth: 1.5)
        }
      }
    }
  }
}

private struct SparklineSeries {
  let normalizedSamples: [Double]

  init?(data: [Double]) {
    guard
      data.count > 1,
      let peakValue = data.max(),
      peakValue > 0
    else {
      return nil
    }

    normalizedSamples = data.map { $0 / peakValue }
  }

  var sampleCount: Int {
    normalizedSamples.count
  }

  func linePath(in geometry: SparklineGeometry) -> Path {
    Path { path in
      path.move(to: point(at: 0, in: geometry))
      for index in normalizedSamples.indices.dropFirst() {
        path.addLine(to: point(at: index, in: geometry))
      }
    }
  }

  func areaPath(in geometry: SparklineGeometry) -> Path {
    Path { path in
      path.move(to: point(at: 0, in: geometry))
      for index in normalizedSamples.indices.dropFirst() {
        path.addLine(to: point(at: index, in: geometry))
      }
      path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height))
      path.addLine(to: CGPoint(x: 0, y: geometry.size.height))
      path.closeSubpath()
    }
  }

  private func point(at index: Int, in geometry: SparklineGeometry) -> CGPoint {
    CGPoint(
      x: Double(index) * geometry.stepX,
      y: geometry.size.height - normalizedSamples[index] * geometry.size.height
    )
  }
}

private struct SparklineGeometry {
  let sampleCount: Int
  let size: CGSize

  var stepX: Double {
    guard sampleCount > 1 else { return 0 }
    return size.width / Double(sampleCount - 1)
  }
}
