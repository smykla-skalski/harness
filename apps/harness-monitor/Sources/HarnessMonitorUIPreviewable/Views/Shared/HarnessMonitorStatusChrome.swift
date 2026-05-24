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
  @Environment(\.fontScale)
  private var fontScale

  private var footnoteFont: Font {
    HarnessMonitorTextSize.scaledFont(
      .system(.footnote, design: .rounded, weight: .semibold),
      by: fontScale
    )
  }

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
        .font(footnoteFont)
    }
    .harnessCellPadding()
    .modifier(
      HarnessMonitorStatusPillChromeModifier(chrome: chrome, tint: HarnessMonitorTheme.accent))
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
  @Environment(\.fontScale)
  private var fontScale

  private var titleFont: Font {
    HarnessMonitorTextSize.scaledFont(
      .system(.headline, design: .rounded, weight: .semibold),
      by: fontScale
    )
  }
  private var subtitleFont: Font {
    HarnessMonitorTextSize.scaledFont(
      .system(.subheadline, design: .rounded, weight: .medium),
      by: fontScale
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(titleFont)
        .accessibilityAddTraits(.isHeader)
      Text(subtitle)
        .font(subtitleFont)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
  }
}

struct HarnessMonitorBadge: View {
  let value: String
  @Environment(\.fontScale)
  private var fontScale

  private var valueFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption.bold(), by: fontScale)
  }

  var body: some View {
    Text(value)
      .font(valueFont)
      .harnessPillPadding()
      .harnessContentPill(tint: HarnessMonitorTheme.accent)
  }
}

extension View {
  public func liveActivityBorder(isActive: Bool) -> some View {
    modifier(LiveActivityBorderModifier(isActive: isActive))
  }

  public func harnessSelectionOutline(
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

  public func harnessContentPill(tint: Color = HarnessMonitorTheme.ink) -> some View {
    modifier(HarnessMonitorContentPillModifier(tint: tint))
  }

  public func harnessControlPill(tint: Color = HarnessMonitorTheme.ink) -> some View {
    modifier(HarnessMonitorControlPillModifier(tint: tint))
  }

  public func harnessPillPadding() -> some View {
    self
      .padding(.horizontal, HarnessMonitorTheme.pillPaddingH)
      .harnessOpticallyBalancedVerticalPadding(HarnessMonitorTheme.pillPaddingV)
  }

  /// Replaces a symmetric `.padding(.vertical, value)` with an asymmetric
  /// inset that biases 1 point of padding from the top to the bottom. SwiftUI
  /// `Text` reports the full line box (ascender + descender) as its size, so
  /// symmetric vertical padding centres the *box* — not the visible glyphs.
  /// At caption size on macOS, the ascender region above the cap is roughly
  /// one point taller than the descender region below the baseline, which
  /// makes the visible text ride high in the pill and leaves the bottom of
  /// the pill looking emptier than the top.
  ///
  /// Shifting one point of inset from the top to the bottom pulls the cap-to-
  /// baseline mid-line back toward the pill's geometric centre without
  /// changing the total height. Use this in place of `.padding(.vertical, X)`
  /// on any pill, chip, or badge that wraps caption-class text.
  public func harnessOpticallyBalancedVerticalPadding(_ value: CGFloat) -> some View {
    let shift: CGFloat = 1
    return
      self
      .padding(.top, max(0, value - shift))
      .padding(.bottom, value + shift)
  }

  /// Overrides this text view's `VerticalAlignment.center` guide so it
  /// returns the visible glyph midline instead of the line-box midline.
  /// SwiftUI `Text` reports the full line box (ascender + descender) as
  /// its size, so default `.center` alignment in an `HStack` pairs the
  /// text's line-box midline with sibling views — but the visible glyph
  /// row sits above the midline because the descender region under the
  /// baseline is empty for most label text. Apply this to the text in a
  /// pill so adjacent glyphs of any kind (swatch dots, indicator shapes,
  /// custom badges) line up with the visible characters instead of the
  /// empty line-box centre. Sibling glyphs need no modifier — their
  /// default geometric centre still aligns to `HStack`'s `.center`,
  /// which now points at the text's optical centre instead of its box
  /// centre.
  ///
  /// The midline is computed as `firstTextBaseline × 0.7`, a generic
  /// compromise between the cap-midline (`× 0.63` for SF Pro digits like
  /// `+1`) and the x-height midline (`× 0.74` for SF Pro lowercase like
  /// `area/ci`). It's derived from live `firstTextBaseline`, so it
  /// scales with Dynamic Type and works across caption, callout, and
  /// body styles without hard-coding any font-size numbers.
  public func harnessOpticalTextCenter() -> some View {
    alignmentGuide(VerticalAlignment.center) { dim in
      dim[.firstTextBaseline] * 0.7
    }
  }

  public func harnessCellPadding() -> some View {
    self
      .padding(.horizontal, HarnessMonitorTheme.sectionSpacing)
      .padding(.vertical, HarnessMonitorTheme.itemSpacing)
  }
}
