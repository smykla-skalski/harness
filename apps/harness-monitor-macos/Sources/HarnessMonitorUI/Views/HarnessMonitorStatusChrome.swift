import HarnessMonitorKit
import SwiftUI

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
              RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusLG, style: .continuous)
                .stroke(
                  HarnessMonitorTheme.success.opacity(0.18 * phase.opacity),
                  lineWidth: 1
                )
            )
            .shadow(
              color: HarnessMonitorTheme.success.opacity(0.08 * phase.opacity),
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

struct HarnessMonitorLoadingStateView: View {
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
    HStack(spacing: HarnessMonitorTheme.itemSpacing) {
      HarnessMonitorSpinner(size: 14)
      Text(title)
        .scaledFont(.system(.footnote, design: .rounded, weight: .semibold))
    }
    .harnessCellPadding()
    .modifier(HarnessMonitorStatusPillChromeModifier(chrome: chrome, tint: HarnessMonitorTheme.accent))
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

private struct HarnessMonitorContentPillModifier: ViewModifier {
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

private struct HarnessMonitorControlPillModifier: ViewModifier {
  let tint: Color

  func body(content: Content) -> some View {
    content.harnessControlPillGlass(tint: tint)
  }
}

private struct HarnessMonitorStatusPillChromeModifier: ViewModifier {
  let chrome: HarnessMonitorLoadingStateView.Chrome
  let tint: Color

  func body(content: Content) -> some View {
    switch chrome {
    case .content:
      content.modifier(HarnessMonitorContentPillModifier(tint: tint))
    case .control:
      content.modifier(HarnessMonitorControlPillModifier(tint: tint))
    }
  }
}

private struct HarnessMonitorSelectionOutlineModifier: ViewModifier {
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

struct HarnessMonitorActionHeader: View {
  let title: String
  let subtitle: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      Text(subtitle)
        .scaledFont(.system(.subheadline, design: .rounded, weight: .medium))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
  }
}

struct HarnessMonitorBadge: View {
  let value: String

  var body: some View {
    Text(value)
      .scaledFont(.caption.bold())
      .harnessPillPadding()
      .harnessContentPill(tint: HarnessMonitorTheme.accent)
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
      HarnessMonitorSelectionOutlineModifier(
        isSelected: isSelected,
        cornerRadius: cornerRadius,
        lineWidth: lineWidth
      )
    )
  }

  func harnessContentPill(tint: Color = HarnessMonitorTheme.ink) -> some View {
    modifier(HarnessMonitorContentPillModifier(tint: tint))
  }

  func harnessControlPill(tint: Color = HarnessMonitorTheme.ink) -> some View {
    modifier(HarnessMonitorControlPillModifier(tint: tint))
  }

  func harnessPillPadding() -> some View {
    self
      .padding(.horizontal, HarnessMonitorTheme.pillPaddingH)
      .padding(.vertical, HarnessMonitorTheme.pillPaddingV)
  }

  func harnessCellPadding() -> some View {
    self
      .padding(.horizontal, HarnessMonitorTheme.sectionSpacing)
      .padding(.vertical, HarnessMonitorTheme.itemSpacing)
  }
}
