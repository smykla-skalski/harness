import HarnessMonitorKit
import SwiftUI

struct WorkspaceSidebarRow: View {
  let snapshot: AgentTuiSnapshot
  let title: String
  @Environment(\.fontScale)
  private var fontScale

  private var brandSymbol: ProviderBrandSymbol? {
    ProviderBrandSymbol(runtimeString: snapshot.runtime)
  }

  private var relativeUpdatedAt: String {
    formatRelativeUpdatedAt(snapshot.updatedAt)
  }

  private var accessibilityLabelText: String {
    "\(title), \(runtimeDisplayLabel(brandSymbol?.rawValue ?? snapshot.runtime)), \(snapshot.status.title), updated \(relativeUpdatedAt)"
  }

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.itemSpacing) {
      Image(systemName: "terminal")
        .imageScale(.large)
        .foregroundStyle(agentTuiStatusColor(for: snapshot.status))
        .accessibilityHidden(true)

      WorkspaceSidebarRowText(
        title: title,
        status: snapshot.status,
        relativeUpdatedAt: relativeUpdatedAt
      )
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .trailing) {
      WorkspaceSidebarRowBrandOverlay(brandSymbol: brandSymbol)
    }
    .clipped()
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabelText)
  }
}

private struct WorkspaceSidebarRowText: View {
  let title: String
  let status: AgentTuiStatus
  let relativeUpdatedAt: String

  private var statusGlyph: String {
    switch status {
    case .running:
      "circle.fill"
    case .stopped:
      "pause.circle.fill"
    case .exited:
      "checkmark.circle.fill"
    case .failed:
      "xmark.octagon.fill"
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .scaledFont(.body)
        .lineLimit(1)
        .truncationMode(.tail)
      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        Image(systemName: statusGlyph)
          .imageScale(.small)
          .foregroundStyle(agentTuiStatusColor(for: status))
          .accessibilityHidden(true)
        Text("\(status.title) · \(relativeUpdatedAt)")
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
  }
}

private struct WorkspaceSidebarRowBrandOverlay: View {
  let brandSymbol: ProviderBrandSymbol?

  var body: some View {
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
}

public struct AutoSpawnedBadgeView: View {
  public let agentID: String

  public init(agentID: String) {
    self.agentID = agentID
  }

  public var body: some View {
    Image(systemName: "sparkles")
      .imageScale(.small)
      .symbolRenderingMode(.hierarchical)
      .foregroundStyle(.white)
      .padding(4)
      .background(HarnessMonitorTheme.accent, in: Circle())
      .accessibilityElement()
      .accessibilityLabel(Text("Auto-spawned reviewer"))
      .accessibilityIdentifier(HarnessMonitorAccessibility.autoSpawnedBadge(agentID))
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

  private var relativeUpdatedAt: String {
    formatRelativeUpdatedAt(snapshot.updatedAt)
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
        Text("\(snapshot.status.title) · \(relativeUpdatedAt)")
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title), run, \(snapshot.status.title), updated \(relativeUpdatedAt)")
  }
}
