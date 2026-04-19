import HarnessMonitorKit
import SwiftUI

struct AgentTuiSidebarRow: View {
  let snapshot: AgentTuiSnapshot
  let title: String
  @Environment(\.fontScale)
  private var fontScale

  private var brandSymbol: ProviderBrandSymbol? {
    ProviderBrandSymbol(runtimeString: snapshot.runtime)
  }

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.itemSpacing) {
      Image(systemName: "terminal")
        .imageScale(.large)
        .foregroundStyle(agentTuiStatusColor(for: snapshot.status))
        .accessibilityHidden(true)

      Text(title)
        .scaledFont(.body)
        .lineLimit(1)
        .truncationMode(.tail)
    }
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
    .clipped()
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(title), \(brandSymbol?.rawValue ?? snapshot.runtime), \(snapshot.status.title)"
    )
  }
}

struct CodexRunSidebarRow: View {
  let snapshot: CodexRunSnapshot
  let title: String

  private var statusColor: Color {
    switch snapshot.status {
    case .running:
      .green
    case .waitingApproval:
      .orange
    case .queued:
      .yellow
    case .completed:
      .secondary
    case .failed, .cancelled:
      .red
    }
  }

  private var symbolName: String {
    switch snapshot.status {
    case .waitingApproval:
      "hand.raised.fill"
    case .completed:
      "checkmark.circle.fill"
    case .failed, .cancelled:
      "xmark.octagon.fill"
    case .queued, .running:
      "sparkles"
    }
  }

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.itemSpacing) {
      Image(systemName: symbolName)
        .imageScale(.large)
        .foregroundStyle(statusColor)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .scaledFont(.body)
          .lineLimit(1)
          .truncationMode(.tail)
        Text(snapshot.status.title)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(1)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title), Codex, \(snapshot.status.title)")
  }
}
