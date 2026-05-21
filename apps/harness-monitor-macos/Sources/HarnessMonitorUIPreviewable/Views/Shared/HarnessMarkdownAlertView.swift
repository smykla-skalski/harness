import SwiftUI

struct HarnessMarkdownAlertView: View {
  let alert: HarnessMarkdownAlert
  let settings: HarnessMarkdownRenderSettings
  let style: HarnessMarkdownResolvedRenderSettings

  private let accentRuleWidth: CGFloat = 8
  private let cornerRadius = HarnessMonitorTheme.cornerRadiusMD

  var body: some View {
    let accent = style.colors.alertAccent(for: alert.kind)
    HStack(alignment: .top, spacing: cardContentSpacing) {
      accentRail(accent: accent)
      VStack(
        alignment: .leading,
        spacing: visibleBodyBlocks.isEmpty
          ? 0
          : max(style.spacing.nestedBlock, HarnessMonitorTheme.spacingSM)
      ) {
        header
        if !visibleBodyBlocks.isEmpty {
          HarnessMarkdownBlockStackView(
            blocks: visibleBodyBlocks,
            settings: settings,
            style: style,
            spacing: style.spacing.nestedBlock
          )
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(cardPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(alignment: .bottomTrailing) {
      backgroundGlyph(accent: accent)
    }
    .background(cardBackground(accent: accent))
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .overlay(cardBorder(accent: accent))
    .padding(.top, HarnessMonitorTheme.spacingXS)
    .padding(.bottom, HarnessMonitorTheme.spacingXS + style.spacing.alertBottomMargin)
    .accessibilityElement(children: .contain)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var header: some View {
    Text(alert.kind.title)
      .font(style.typography.body.font.weight(.semibold))
      .foregroundStyle(style.colors.text)
      .accessibilityAddTraits(.isHeader)
  }

  private func backgroundGlyph(accent: Color) -> some View {
    Image(systemName: alert.kind.symbolName)
      .font(.system(size: backgroundGlyphSize, weight: .black, design: .rounded))
      .symbolRenderingMode(.hierarchical)
      .foregroundStyle(accent.opacity(0.30))
      .rotationEffect(.degrees(-8))
      .offset(x: 30, y: 30)
      .accessibilityHidden(true)
      .allowsHitTesting(false)
  }

  private func cardBackground(accent: Color) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      .fill(HarnessMonitorTheme.ink.opacity(0.05))
      .overlay {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(accent.opacity(0.10))
      }
  }

  private func cardBorder(accent: Color) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      .strokeBorder(HarnessMonitorTheme.controlBorder.opacity(0.55), lineWidth: 1)
      .overlay {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .strokeBorder(accent.opacity(0.22), lineWidth: 1)
      }
  }

  private func accentRail(accent: Color) -> some View {
    RoundedRectangle(cornerRadius: accentRuleWidth / 2, style: .continuous)
      .fill(accent)
      .frame(width: accentRuleWidth)
      .accessibilityHidden(true)
  }

  private var backgroundGlyphSize: CGFloat {
    visibleBodyBlocks.isEmpty ? 94 : 124
  }

  private var cardPadding: CGFloat {
    max(
      HarnessMonitorTheme.cardPadding,
      style.spacing.quoteContentGap + HarnessMonitorTheme.spacingXS
    )
  }

  private var cardContentSpacing: CGFloat {
    max(HarnessMonitorTheme.spacingSM, style.spacing.quoteContentGap)
  }

  private var visibleBodyBlocks: [HarnessMarkdownBlock] {
    alert.blocks.filter(\.rendersVisibleMarkdownContent)
  }
}
