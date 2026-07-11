import SwiftUI

private struct TaskBoardCardBackgroundGlyphModifier: ViewModifier {
  let systemImage: String?
  let tint: Color
  let cornerRadius: CGFloat
  let providerSymbol: ProviderBrandSymbol?

  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency
  @Environment(\.colorScheme)
  private var colorScheme
  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast
  @Environment(\.fontScale)
  private var fontScale

  private var glyphSize: CGFloat {
    82 * min(SessionWindowFontScale.metricsScale(for: fontScale), 1.18)
  }

  private var providerGlyphSize: CGFloat {
    switch providerSymbol {
    case .kuma:
      glyphSize * 1.8
    default:
      glyphSize
    }
  }

  private var glyphRotation: Angle {
    switch providerSymbol {
    case .kuma:
      .degrees(-37)
    default:
      .degrees(-8)
    }
  }

  private var glyphOffset: CGSize {
    switch providerSymbol {
    case .kuma:
      CGSize(width: 52, height: 62)
    default:
      CGSize(width: 20, height: 24)
    }
  }

  private var resolvedProviderSymbol: ProviderBrandSymbol {
    providerSymbol ?? .kong
  }

  private var systemGlyphOpacity: Double {
    providerSymbol == nil && systemImage != nil ? 0.22 : 0
  }

  private var providerGlyphTint: Color {
    let baseColor: Color = colorScheme == .dark ? .white : .black
    let opacity: Double

    switch (reduceTransparency, colorSchemeContrast) {
    case (true, .increased):
      opacity = 0.22
    case (true, _):
      opacity = 0.18
    case (false, .increased):
      opacity = 0.16
    case (false, _):
      opacity = 0.12
    }

    return baseColor.opacity(opacity)
  }

  private var providerGlyphColorMode: ProviderBrandSymbolColorMode {
    .custom(providerGlyphTint)
  }

  func body(content: Content) -> some View {
    content
      .background(alignment: .bottomTrailing) {
        ZStack {
          if let systemImage {
            Image(systemName: systemImage)
              .font(.system(size: glyphSize, weight: .black, design: .rounded))
              .symbolRenderingMode(.hierarchical)
              .foregroundStyle(tint.opacity(systemGlyphOpacity))
          }
          ProviderBrandSymbolView(
            symbol: resolvedProviderSymbol,
            colorMode: providerGlyphColorMode,
            size: providerGlyphSize
          )
          .opacity(providerSymbol == nil ? 0 : 1)
        }
        .rotationEffect(glyphRotation)
        .offset(x: glyphOffset.width, y: glyphOffset.height)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
      }
      .clipShape(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      )
  }
}

extension View {
  func taskBoardCardBackgroundGlyph(
    systemImage: String?,
    tint: Color,
    cornerRadius: CGFloat,
    providerSymbol: ProviderBrandSymbol? = nil
  ) -> some View {
    modifier(
      TaskBoardCardBackgroundGlyphModifier(
        systemImage: systemImage,
        tint: tint,
        cornerRadius: cornerRadius,
        providerSymbol: providerSymbol
      )
    )
  }
}
