import HarnessMonitorKit
import SwiftUI

struct AgentTuiSidebarRow: View {
  let snapshot: AgentTuiSnapshot
  let title: String
  @Environment(\.fontScale) private var fontScale

  private var brandSymbol: ProviderBrandSymbol? {
    ProviderBrandSymbol(runtimeString: snapshot.runtime)
  }

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.sectionSpacing) {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
        .fill(agentTuiStatusColor(for: snapshot.status))
        .frame(width: 4)
        .accessibilityHidden(true)

      Text(title)
        .scaledFont(.body)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .padding(.horizontal, HarnessMonitorTheme.sectionSpacing)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .trailing) {
      Group {
        if let brandSymbol {
          ProviderBrandSymbolView(
            symbol: brandSymbol,
            colorMode: .automaticContrast,
            size: 36
          )
          .opacity(0.12)
          .offset(x: 6, y: 4)
        } else {
          Image(systemName: "terminal")
            .font(.system(size: 28))
            .foregroundStyle(.secondary)
            .opacity(0.12)
            .offset(x: 6, y: 4)
        }
      }
      .accessibilityHidden(true)
      .allowsHitTesting(false)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(title), \(brandSymbol?.rawValue ?? snapshot.runtime), \(snapshot.status.title)"
    )
  }
}
