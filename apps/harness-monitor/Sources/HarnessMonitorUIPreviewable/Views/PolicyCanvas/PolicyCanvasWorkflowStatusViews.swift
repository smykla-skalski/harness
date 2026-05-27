import SwiftUI

struct PolicyCanvasWorkflowStatusStrip: View {
  let cards: [PolicyCanvasWorkflowStatusCardModel]

  var body: some View {
    HStack(spacing: 10) {
      ForEach(cards) { card in
        PolicyCanvasWorkflowStatusCard(card: card)
      }
    }
  }
}

struct PolicyCanvasWorkflowStatusCardModel: Identifiable {
  let id: String
  let title: String
  let detail: String
  let systemImage: String
  let tone: PolicyCanvasWorkflowTone
}

private struct PolicyCanvasWorkflowStatusCard: View {
  let card: PolicyCanvasWorkflowStatusCardModel

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: card.systemImage)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(card.tone.tint)
        .frame(width: 14)
        .accessibilityHidden(true)

      Text(card.title)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
        .textCase(.uppercase)

      Text(card.detail)
        .scaledFont(.caption.weight(.medium))
        .foregroundStyle(PolicyCanvasVisualStyle.primaryText)
        .lineLimit(1)
        .truncationMode(.tail)

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      PolicyCanvasVisualStyle.surface,
      in: RoundedRectangle(cornerRadius: HarnessMonitorTheme.pillCornerRadius, style: .continuous)
    )
    .overlay(alignment: .leading) {
      RoundedRectangle(cornerRadius: 1.5)
        .fill(card.tone.tint.opacity(0.74))
        .frame(width: 3)
        .padding(.vertical, 7)
    }
    .overlay {
      RoundedRectangle(
        cornerRadius: HarnessMonitorTheme.pillCornerRadius,
        style: .continuous
      )
      .stroke(card.tone.border, lineWidth: 1)
    }
  }
}

enum PolicyCanvasWorkflowTone {
  case ready
  case warning
  case blocked
  case active

  var tint: Color {
    switch self {
    case .ready:
      return PolicyCanvasVisualStyle.readyTint
    case .warning:
      return PolicyCanvasVisualStyle.warningTint
    case .blocked:
      return PolicyCanvasVisualStyle.blockedTint
    case .active:
      return PolicyCanvasVisualStyle.activeTint
    }
  }

  var background: Color {
    tint.opacity(0.08)
  }

  var border: Color {
    tint.opacity(0.18)
  }
}
