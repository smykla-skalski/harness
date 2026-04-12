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
    HStack(spacing: HarnessMonitorTheme.itemSpacing) {
      Group {
        if let brandSymbol {
          ProviderBrandSymbolView(
            symbol: brandSymbol,
            colorMode: .automaticContrast,
            size: 14
          )
        } else {
          Image(systemName: "terminal")
            .imageScale(.small)
            .foregroundStyle(.secondary)
            .frame(width: 14, height: 14)
        }
      }
      .accessibilityHidden(true)

      Text(title)
        .scaledFont(.body)
        .lineLimit(1)
        .truncationMode(.tail)

      Spacer(minLength: 0)

      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
        .fill(agentTuiStatusColor(for: snapshot.status))
        .frame(width: 4)
        .accessibilityHidden(true)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(title), \(brandSymbol?.rawValue ?? snapshot.runtime), \(snapshot.status.title)"
    )
  }
}
