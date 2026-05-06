import AppKit
import SwiftUI

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
        .fill(Color.primary.opacity(0.08))
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
