import AppKit
import SwiftUI

private final class ProviderBrandSymbolBundleToken {}

private let providerBrandSymbolBundle = Bundle(for: ProviderBrandSymbolBundleToken.self)

private enum ProviderBrandSymbolContrast {
  static let darkForeground = Color.black
  static let lightForeground = Color.white

  static func foreground(for background: Color) -> Color {
    guard let rgbColor = NSColor(background).usingColorSpace(.deviceRGB) else {
      return lightForeground
    }

    let backgroundLuminance = relativeLuminance(
      red: rgbColor.redComponent,
      green: rgbColor.greenComponent,
      blue: rgbColor.blueComponent
    )

    let contrastWithLight = (1.0 + 0.05) / (backgroundLuminance + 0.05)
    let contrastWithDark = (backgroundLuminance + 0.05) / 0.05

    return contrastWithDark >= contrastWithLight ? darkForeground : lightForeground
  }

  private static func relativeLuminance(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGFloat {
    (0.2126 * linearized(red)) + (0.7152 * linearized(green)) + (0.0722 * linearized(blue))
  }

  private static func linearized(_ component: CGFloat) -> CGFloat {
    if component <= 0.04045 {
      return component / 12.92
    }
    return pow((component + 0.055) / 1.055, 2.4)
  }
}

public enum ProviderBrandSymbolColorMode {
  case original, light, dark
  case custom(Color)
  case automaticContrast
  case automaticContrastAgainst(Color)

  public static func automaticContrast(on background: Color) -> Self {
    .automaticContrastAgainst(background)
  }
}

public enum ProviderBrandSymbol: String, CaseIterable, Identifiable {
  case openAI = "OpenAI"
  case anthropic = "Anthropic"
  case claude = "Claude"
  case gemini = "Gemini"
  case copilot = "Copilot"
  case mistral = "Mistral"

  public var id: String { rawValue }

  var assetName: String {
    switch self {
    case .openAI:
      "ProviderSymbol-openai"
    case .anthropic:
      "ProviderSymbol-anthropic"
    case .claude:
      "ProviderSymbol-claude"
    case .gemini:
      "ProviderSymbol-gemini"
    case .copilot:
      "ProviderSymbol-copilot"
    case .mistral:
      "ProviderSymbol-mistral"
    }
  }
}

public struct ProviderBrandSymbolView: View {
  public let symbol: ProviderBrandSymbol
  public let colorMode: ProviderBrandSymbolColorMode
  public let size: CGFloat

  @Environment(\.colorScheme)
  private var colorScheme

  public init(
    symbol: ProviderBrandSymbol,
    colorMode: ProviderBrandSymbolColorMode = .original,
    size: CGFloat = 16
  ) {
    self.symbol = symbol
    self.colorMode = colorMode
    self.size = size
  }

  private var resolvedTint: Color? {
    switch colorMode {
    case .original:
      nil
    case .light:
      .white
    case .dark:
      .black
    case .custom(let color):
      color
    case .automaticContrast:
      colorScheme == .dark ? .white : .black
    case .automaticContrastAgainst(let background):
      ProviderBrandSymbolContrast.foreground(for: background)
    }
  }

  public var body: some View {
    symbolImage
    .help(symbol.rawValue)
    .accessibilityLabel(symbol.rawValue)
  }

  @ViewBuilder private var symbolImage: some View {
    if let tint = resolvedTint {
      Image(symbol.assetName, bundle: providerBrandSymbolBundle)
        .renderingMode(.template)
        .resizable()
        .interpolation(.high)
        .antialiased(true)
        .scaledToFit()
        .frame(width: size, height: size)
        .foregroundStyle(tint)
    } else {
      Image(symbol.assetName, bundle: providerBrandSymbolBundle)
        .renderingMode(.original)
        .resizable()
        .interpolation(.high)
        .antialiased(true)
        .scaledToFit()
        .frame(width: size, height: size)
    }
  }
}

public struct ProviderBrandSymbolStrip: View {
  public let colorMode: ProviderBrandSymbolColorMode
  public let size: CGFloat
  public let spacing: CGFloat
  private let symbols = ProviderBrandSymbol.allCases

  public init(
    colorMode: ProviderBrandSymbolColorMode = .original,
    size: CGFloat = 16,
    spacing: CGFloat = 8
  ) {
    self.colorMode = colorMode
    self.size = size
    self.spacing = spacing
  }

  public var body: some View {
    HStack(spacing: spacing) {
      ForEach(symbols) { symbol in
        ProviderBrandSymbolView(symbol: symbol, colorMode: colorMode, size: size)
      }
    }
    .accessibilityElement(children: .contain)
  }
}

#if DEBUG
private struct ProviderBrandSymbolPreviewRow: View {
  let title: String
  let subtitle: String
  let colorMode: ProviderBrandSymbolColorMode
  let surface: Color

  var body: some View {
    HStack(alignment: .center, spacing: 16) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.system(.caption, design: .rounded, weight: .semibold))
          .foregroundStyle(.primary)
        Text(subtitle)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(width: 124, alignment: .leading)

      ProviderBrandSymbolStrip(
        colorMode: colorMode,
        size: 18,
        spacing: 10
      )
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .background {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .fill(surface)
      }
      .overlay {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
      }
    }
  }
}

private struct ProviderBrandSymbolPreviewCard: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Provider Symbols")
          .font(.system(.headline, design: .rounded, weight: .semibold))
        Text("Vector brand marks across original, forced, and automatic contrast modes.")
          .font(.system(.caption, design: .rounded))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      VStack(spacing: 10) {
        ProviderBrandSymbolPreviewRow(
          title: "Original",
          subtitle: "Source brand colors",
          colorMode: .original,
          surface: .primary.opacity(0.06)
        )
        ProviderBrandSymbolPreviewRow(
          title: "Auto",
          subtitle: "Uses window appearance",
          colorMode: .automaticContrast,
          surface: .primary.opacity(0.08)
        )
        ProviderBrandSymbolPreviewRow(
          title: "Auto / Light",
          subtitle: "Detects light surface",
          colorMode: .automaticContrast(on: .white),
          surface: .white
        )
        ProviderBrandSymbolPreviewRow(
          title: "Auto / Dark",
          subtitle: "Detects dark surface",
          colorMode: .automaticContrast(on: .black),
          surface: .black
        )
        ProviderBrandSymbolPreviewRow(
          title: "Forced Light",
          subtitle: "Manual white tint",
          colorMode: .light,
          surface: .black
        )
        ProviderBrandSymbolPreviewRow(
          title: "Forced Dark",
          subtitle: "Manual black tint",
          colorMode: .dark,
          surface: .white
        )
        ProviderBrandSymbolPreviewRow(
          title: "Custom Accent",
          subtitle: "Manual theme tint",
          colorMode: .custom(.blue),
          surface: Color.blue.opacity(0.14)
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(20)
    .background {
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .fill(.regularMaterial)
    }
  }
}

#Preview("Provider Symbols") {
  ScrollView {
    ProviderBrandSymbolPreviewCard()
      .padding(16)
  }
  .frame(width: 720, height: 760)
  .background(Color.primary.opacity(0.08))
}

#Preview("Provider Symbols Dark") {
  ScrollView {
    ProviderBrandSymbolPreviewCard()
      .padding(16)
  }
  .frame(width: 720, height: 760)
  .background(Color.primary.opacity(0.08))
  .preferredColorScheme(.dark)
}
#endif
