import HarnessMonitorKit
import SwiftUI

@MainActor
public struct SessionOpenRouterRunRow: View {
  public let run: OpenRouterRunSnapshot

  public init(run: OpenRouterRunSnapshot) {
    self.run = run
  }

  public var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: "network")
        .foregroundStyle(HarnessMonitorTheme.accent)
      VStack(alignment: .leading, spacing: 2) {
        Text(run.displayName)
          .scaledFont(.body.weight(.semibold))
          .lineLimit(1)
          .truncationMode(.tail)
        Text(run.model)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer()
      statusDot
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sessionOpenRouterRunRow)
  }

  private var statusDot: some View {
    Circle()
      .fill(statusTint)
      .frame(width: 8, height: 8)
      .accessibilityLabel(run.status.title)
  }

  private var statusTint: Color {
    switch run.status {
    case .pending: HarnessMonitorTheme.secondaryInk
    case .streaming: HarnessMonitorTheme.accent
    case .idle: HarnessMonitorTheme.success
    case .cancelled: HarnessMonitorTheme.caution
    case .failed: HarnessMonitorTheme.danger
    }
  }
}
