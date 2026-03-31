import HarnessKit
import SwiftUI

private let isHarnessUITesting = ProcessInfo.processInfo.environment["HARNESS_UI_TESTS"] == "1"

private func harnessColor(_ name: String) -> Color {
  Color(name, bundle: .main)
}

enum HarnessTheme {
  static let accent = harnessColor("HarnessAccent")
  static let ink = harnessColor("HarnessInk")
  static let warmAccent = harnessColor("HarnessWarmAccent")
  static let success = harnessColor("HarnessSuccess")
  static let caution = harnessColor("HarnessCaution")
  static let danger = harnessColor("HarnessDanger")
  static let controlBorder = harnessColor("HarnessControlBorder")
  static let overlayScrim = harnessColor("HarnessOverlayScrim")
  static let secondaryInk = ink.opacity(0.88)
  static let tertiaryInk = ink.opacity(0.76)
  static let onContrast = Color.white

  // MARK: - Spacing (4pt grid)

  static let spacingXS: CGFloat = 4
  static let spacingSM: CGFloat = 8
  static let spacingMD: CGFloat = 12
  static let spacingLG: CGFloat = 16
  static let spacingXL: CGFloat = 20
  static let spacingXXL: CGFloat = 24

  // MARK: - Corner radius

  static let cornerRadiusSM: CGFloat = 12
  static let cornerRadiusMD: CGFloat = 16
  static let cornerRadiusLG: CGFloat = 20
}

struct LiveActivityBorderModifier: ViewModifier {
  let isActive: Bool
  @State private var flashTrigger = 0
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  private enum FlashPhase: CaseIterable {
    case idle, bright, fade

    var opacity: Double {
      switch self {
      case .idle: 0
      case .bright: 1
      case .fade: 0
      }
    }
  }

  @ViewBuilder
  func body(content: Content) -> some View {
    if reduceMotion {
      content
    } else {
      content
        .onChange(of: isActive) { _, active in
          guard active else { return }
          flashTrigger += 1
        }
        .phaseAnimator(FlashPhase.allCases, trigger: flashTrigger) { view, phase in
          view
            .overlay(
              RoundedRectangle(cornerRadius: HarnessTheme.cornerRadiusLG, style: .continuous)
                .stroke(
                  HarnessTheme.success.opacity(0.18 * phase.opacity),
                  lineWidth: 1
                )
            )
            .shadow(
              color: HarnessTheme.success.opacity(0.08 * phase.opacity),
              radius: 12 * phase.opacity,
              x: 0,
              y: 0
            )
        } animation: { phase in
          switch phase {
          case .idle: .easeOut(duration: 0.75)
          case .bright: .easeIn(duration: 0.15)
          case .fade: .easeOut(duration: 0.75)
          }
        }
    }
  }
}

struct HarnessLoadingStateView: View {
  let title: String
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @State private var animates = false

  var body: some View {
    HStack(spacing: 8) {
      HarnessSpinner(size: 14)
      Text(title)
        .font(.system(.footnote, design: .rounded, weight: .semibold))
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .harnessInfoPill(tint: HarnessTheme.accent)
    .opacity(animates ? 1 : 0.62)
    .scaleEffect(reduceMotion ? 1 : (animates ? 1 : 0.97))
    .animation(
      reduceMotion
        ? .easeOut(duration: 0.2)
        : .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
      value: animates
    )
    .onAppear { animates = true }
  }
}

private struct HarnessInfoPillModifier: ViewModifier {
  let tint: Color
  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency
  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast

  private var fillOpacity: Double {
    if reduceTransparency {
      return colorSchemeContrast == .increased ? 0.34 : 0.26
    }
    return colorSchemeContrast == .increased ? 0.24 : 0.16
  }

  private var strokeOpacity: Double {
    colorSchemeContrast == .increased ? 0.38 : 0.22
  }

  private var strokeWidth: CGFloat {
    colorSchemeContrast == .increased ? 1.5 : 1
  }

  func body(content: Content) -> some View {
    content
      .background {
        Capsule()
          .fill(tint.opacity(fillOpacity))
      }
      .overlay {
        Capsule()
          .strokeBorder(tint.opacity(strokeOpacity), lineWidth: strokeWidth)
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

private struct AccessibilityProbe: View {
  let identifier: String
  let label: String?
  let value: String?

  var body: some View {
    Color.clear
      .allowsHitTesting(false)
      .accessibilityElement()
      .accessibilityLabel(label ?? "")
      .accessibilityValue(value ?? "")
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

private struct HarnessSelectionOutlineModifier: ViewModifier {
  let isSelected: Bool
  let cornerRadius: CGFloat
  let lineWidth: CGFloat

  func body(content: Content) -> some View {
    content.overlay {
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .strokeBorder(.selection, lineWidth: lineWidth)
        .opacity(isSelected ? 1 : 0)
    }
    .animation(.spring(duration: 0.2), value: isSelected)
  }
}

private struct AccessibilityFrameMarkerModifier: ViewModifier {
  let identifier: String

  @ViewBuilder
  func body(content: Content) -> some View {
    if isHarnessUITesting {
      content.overlay {
        AccessibilityFrameMarker(identifier: identifier)
      }
    } else {
      content
    }
  }
}

private struct AccessibilityProbeModifier: ViewModifier {
  let identifier: String
  let label: String?
  let value: String?

  @ViewBuilder
  func body(content: Content) -> some View {
    if isHarnessUITesting {
      content.overlay {
        AccessibilityProbe(
          identifier: identifier,
          label: label,
          value: value
        )
      }
    } else {
      content
    }
  }
}

extension View {
  func liveActivityBorder(isActive: Bool) -> some View {
    modifier(LiveActivityBorderModifier(isActive: isActive))
  }

  func accessibilityFrameMarker(_ identifier: String) -> some View {
    modifier(AccessibilityFrameMarkerModifier(identifier: identifier))
  }

  func accessibilityTestProbe(
    _ identifier: String,
    label: String? = nil,
    value: String? = nil
  ) -> some View {
    modifier(
      AccessibilityProbeModifier(
        identifier: identifier,
        label: label,
        value: value
      )
    )
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

  func harnessInfoPill(tint: Color = HarnessTheme.ink) -> some View {
    modifier(HarnessInfoPillModifier(tint: tint))
  }
}

struct HarnessActionHeader: View {
  let title: String
  let subtitle: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.system(.headline, design: .rounded, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      Text(subtitle)
        .font(.system(.subheadline, design: .rounded, weight: .medium))
        .foregroundStyle(HarnessTheme.secondaryInk)
    }
  }
}

struct HarnessBadge: View {
  let value: String

  var body: some View {
    Text(value)
      .font(.caption.bold())
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .harnessInfoPill(tint: HarnessTheme.accent)
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

func severityColor(for severity: TaskSeverity) -> Color {
  switch severity {
  case .low:
    HarnessTheme.accent.opacity(0.7)
  case .medium:
    HarnessTheme.accent
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

func taskStatusColor(for status: TaskStatus) -> Color {
  switch status {
  case .open:
    HarnessTheme.accent
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
