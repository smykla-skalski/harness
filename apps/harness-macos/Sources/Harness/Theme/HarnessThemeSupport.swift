import AppKit
import Foundation
import HarnessKit
import SwiftUI

struct HarnessLoadingStateView: View {
  let title: String
  @State private var animates = false

  var body: some View {
    HStack(spacing: 10) {
      HarnessSpinner(size: 14)
      Text(title)
        .font(.system(.footnote, design: .rounded, weight: .semibold))
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background {
      HarnessGlassCapsuleBackground()
    }
    .opacity(animates ? 1 : 0.82)
    .scaleEffect(animates ? 1 : 0.985)
    .animation(
      .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
      value: animates
    )
    .onAppear {
      animates = true
    }
  }
}

private struct AccessibilityFrameMarker: View {
  let identifier: String

  var body: some View {
    Color.clear
      .allowsHitTesting(false)
      .accessibilityElement()
      .accessibilityIdentifier(identifier)
  }
}

struct AccessibilityTextMarker: View {
  let identifier: String
  let text: String

  var body: some View {
    Color.clear
      .allowsHitTesting(false)
      .accessibilityElement()
      .accessibilityLabel(text)
      .accessibilityIdentifier(identifier)
  }
}

struct WindowChromeMetricsMarker: View {
  private static let isUITesting = ProcessInfo.processInfo.environment["HARNESS_UI_TESTS"] == "1"

  let identifier: String
  @State private var metrics = "unavailable"

  @ViewBuilder var body: some View {
    if Self.isUITesting {
      ZStack {
        WindowChromeMetricsProbe(metrics: $metrics)
          .frame(width: 0, height: 0)
          .accessibilityHidden(true)
        AccessibilityTextMarker(
          identifier: identifier,
          text: metrics
        )
      }
    }
  }
}

private struct WindowChromeMetricsProbe: NSViewRepresentable {
  @Binding var metrics: String

  func makeCoordinator() -> Coordinator {
    Coordinator(metrics: $metrics)
  }

  func makeNSView(context: Context) -> WindowChromeProbeView {
    let view = WindowChromeProbeView()
    view.onMetricsChange = context.coordinator.update
    return view
  }

  func updateNSView(_ nsView: WindowChromeProbeView, context: Context) {
    nsView.onMetricsChange = context.coordinator.update
    nsView.reportMetrics()
  }

  final class Coordinator {
    private let metrics: Binding<String>

    init(metrics: Binding<String>) {
      self.metrics = metrics
    }

    func update(_ value: String) {
      guard metrics.wrappedValue != value else { return }
      metrics.wrappedValue = value
    }
  }
}

private final class WindowChromeProbeView: NSView {
  var onMetricsChange: (String) -> Void = { _ in }
  private var lastMetrics: String?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    reportMetrics()
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    reportMetrics()
  }

  override func layout() {
    super.layout()
    reportMetrics()
  }

  func reportMetrics() {
    DispatchQueue.main.async { [weak self] in
      self?.publishMetrics()
    }
  }

  private func publishMetrics() {
    guard
      let window,
      let closeButton = window.standardWindowButton(.closeButton),
      let titlebarContainer = closeButton.superview
    else {
      return
    }

    let leadingInset = Int(closeButton.frame.minX.rounded())
    let topInset = Int((titlebarContainer.bounds.maxY - closeButton.frame.maxY).rounded())
    let metrics = "leading=\(leadingInset), top=\(topInset)"

    guard metrics != lastMetrics else { return }
    lastMetrics = metrics
    onMetricsChange(metrics)
  }
}

private struct HarnessSelectionOutlineModifier: ViewModifier {
  let isSelected: Bool
  let cornerRadius: CGFloat
  let lineWidth: CGFloat

  func body(content: Content) -> some View {
    content.overlay {
      if isSelected {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .strokeBorder(.selection, lineWidth: lineWidth)
      }
    }
  }
}

private struct AccessibilityFrameMarkerModifier: ViewModifier {
  private static let isUITesting = ProcessInfo.processInfo.environment["HARNESS_UI_TESTS"] == "1"

  let identifier: String

  @ViewBuilder
  func body(content: Content) -> some View {
    if Self.isUITesting {
      content.overlay {
        AccessibilityFrameMarker(identifier: identifier)
      }
    } else {
      content
    }
  }
}

extension View {
  func harnessCard(
    minHeight: CGFloat? = nil,
    contentPadding: CGFloat = 16
  ) -> some View {
    modifier(HarnessCardModifier(minHeight: minHeight, contentPadding: contentPadding))
  }

  func liveActivityBorder(isActive: Bool) -> some View {
    modifier(LiveActivityBorderModifier(isActive: isActive))
  }

  func accessibilityFrameMarker(_ identifier: String) -> some View {
    modifier(AccessibilityFrameMarkerModifier(identifier: identifier))
  }

  func harnessSelectionOutline(
    isSelected: Bool,
    cornerRadius: CGFloat,
    lineWidth: CGFloat = 1.5
  ) -> some View {
    modifier(
      HarnessSelectionOutlineModifier(
        isSelected: isSelected,
        cornerRadius: cornerRadius,
        lineWidth: lineWidth
      )
    )
  }
}

func harnessActionHeader(title: String, subtitle: String) -> some View {
  VStack(alignment: .leading, spacing: 4) {
    Text(title)
      .font(.system(.headline, design: .rounded, weight: .semibold))
    Text(subtitle)
      .font(.system(.subheadline, design: .rounded, weight: .medium))
      .foregroundStyle(HarnessTheme.secondaryInk)
  }
}

func harnessBadge(_ value: String) -> some View {
  Text(value)
    .font(.caption.bold())
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background {
      HarnessGlassCapsuleBackground()
    }
}

func statusColor(for status: SessionStatus) -> Color {
  switch status {
  case .active:
    HarnessTheme.success
  case .paused:
    HarnessTheme.caution
  case .ended:
    HarnessTheme.ink.opacity(0.55)
  }
}

func severityColor(
  for severity: TaskSeverity,
  style: HarnessThemeStyle
) -> Color {
  switch severity {
  case .low:
    HarnessTheme.accent(for: style).opacity(0.7)
  case .medium:
    HarnessTheme.accent(for: style)
  case .high:
    HarnessTheme.warmAccent
  case .critical:
    HarnessTheme.danger
  }
}

func signalStatusColor(for status: SessionSignalStatus) -> Color {
  switch status {
  case .pending, .deferred:
    HarnessTheme.caution
  case .acknowledged:
    HarnessTheme.success
  case .rejected, .expired:
    HarnessTheme.danger
  }
}

func taskStatusColor(
  for status: TaskStatus,
  style: HarnessThemeStyle
) -> Color {
  switch status {
  case .open:
    HarnessTheme.accent(for: style)
  case .inProgress:
    HarnessTheme.warmAccent
  case .inReview:
    HarnessTheme.caution
  case .done:
    HarnessTheme.success
  case .blocked:
    HarnessTheme.danger
  }
}
