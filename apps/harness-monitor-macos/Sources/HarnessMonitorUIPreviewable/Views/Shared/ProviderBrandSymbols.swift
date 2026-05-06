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

  public init?(runtimeString: String) {
    switch runtimeString.lowercased() {
    case "claude", "anthropic":
      self = .claude
    case "codex", "openai":
      self = .openAI
    case "gemini":
      self = .gemini
    case "copilot":
      self = .copilot
    case "mistral", "vibe":
      self = .mistral
    default:
      return nil
    }
  }

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
