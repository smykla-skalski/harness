import HarnessMonitorKit
import SwiftUI

struct MCPStatusBanner: View {
  let status: HarnessMonitorMCPStatusSnapshot

  private var tint: Color {
    MCPStatusViewSupport.tint(for: status.tone)
  }

  var body: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.itemSpacing) {
      Image(systemName: status.symbolName)
        .scaledFont(.caption)
        .accessibilityHidden(true)
      Text(status.detail)
        .scaledFont(.caption.weight(.medium))
      Spacer(minLength: 0)
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
    .foregroundStyle(tint)
    .modifier(ChromeBannerSurfaceModifier(tint: tint))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(status.accessibilityLabel))
    .accessibilityValue(Text(status.accessibilityValue))
    .accessibilityIdentifier(HarnessMonitorAccessibility.mcpBanner)
  }
}
