import HarnessKit
import SwiftUI

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

  // MARK: - Semantic layout tokens

  /// Standard padding inside interactive cards and content cells.
  static let cardPadding: CGFloat = spacingMD

  /// Horizontal + vertical padding for small pills and badges.
  static let pillPaddingH: CGFloat = spacingSM
  static let pillPaddingV: CGFloat = spacingXS

  /// Vertical gap between top-level sections (tasks, agents, timeline).
  static let sectionSpacing: CGFloat = spacingMD

  /// Vertical gap between items within a group.
  static let itemSpacing: CGFloat = spacingSM

  // MARK: - Typography

  /// Letter-spacing for ALL CAPS labels to improve readability per HIG.
  static let uppercaseTracking: CGFloat = 0.5

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
  enum Chrome {
    case content
    case control
  }

  let title: String
  let chrome: Chrome
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @State private var animates = false

  init(title: String) {
    self.init(title: title, chrome: .content)
  }

  init(title: String, chrome: Chrome) {
    self.title = title
    self.chrome = chrome
  }

  var body: some View {
    HStack(spacing: HarnessTheme.itemSpacing) {
      HarnessSpinner(size: 14)
      Text(title)
        .scaledFont(.system(.footnote, design: .rounded, weight: .semibold))
    }
    .harnessCellPadding()
    .modifier(HarnessStatusPillChromeModifier(chrome: chrome, tint: HarnessTheme.accent))
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

private struct HarnessContentPillModifier: ViewModifier {
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

private struct HarnessControlPillModifier: ViewModifier {
  let tint: Color

  func body(content: Content) -> some View {
    content.harnessControlPillGlass(tint: tint)
  }
}

private struct HarnessStatusPillChromeModifier: ViewModifier {
  let chrome: HarnessLoadingStateView.Chrome
  let tint: Color

  func body(content: Content) -> some View {
    switch chrome {
    case .content:
      content.modifier(HarnessContentPillModifier(tint: tint))
    case .control:
      content.modifier(HarnessControlPillModifier(tint: tint))
    }
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

extension View {
  func liveActivityBorder(isActive: Bool) -> some View {
    modifier(LiveActivityBorderModifier(isActive: isActive))
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

  func harnessContentPill(tint: Color = HarnessTheme.ink) -> some View {
    modifier(HarnessContentPillModifier(tint: tint))
  }

  func harnessControlPill(tint: Color = HarnessTheme.ink) -> some View {
    modifier(HarnessControlPillModifier(tint: tint))
  }

  func harnessPillPadding() -> some View {
    self
      .padding(.horizontal, HarnessTheme.pillPaddingH)
      .padding(.vertical, HarnessTheme.pillPaddingV)
  }

  func harnessCellPadding() -> some View {
    self
      .padding(.horizontal, HarnessTheme.sectionSpacing)
      .padding(.vertical, HarnessTheme.itemSpacing)
  }
}

struct HarnessActionHeader: View {
  let title: String
  let subtitle: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      Text(subtitle)
        .scaledFont(.system(.subheadline, design: .rounded, weight: .medium))
        .foregroundStyle(HarnessTheme.secondaryInk)
    }
  }
}

struct HarnessBadge: View {
  let value: String

  var body: some View {
    Text(value)
      .scaledFont(.caption.bold())
      .harnessPillPadding()
      .harnessContentPill(tint: HarnessTheme.accent)
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
