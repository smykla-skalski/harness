import HarnessMonitorKit
import SwiftUI

enum AgentsConfigPillState {
  case `default`
  case set
  case additive

  fileprivate var accessibilityValue: String {
    switch self {
    case .default:
      "default"
    case .set:
      "set"
    case .additive:
      "additive"
    }
  }

  fileprivate var fillOpacity: Double {
    switch self {
    case .set:
      0.18
    case .default, .additive:
      0
    }
  }

  fileprivate var strokeOpacity: Double {
    switch self {
    case .set:
      0
    case .default, .additive:
      0.7
    }
  }

  fileprivate var hasLeadingPlus: Bool {
    self == .additive
  }
}

struct AgentsConfigPill<MenuContent: View>: View {
  let label: String
  let value: String?
  let state: AgentsConfigPillState
  let accessibilityLabel: String
  let accessibilityIdentifier: String?
  @ViewBuilder let menuContent: () -> MenuContent

  init(
    label: String,
    value: String? = nil,
    state: AgentsConfigPillState,
    accessibilityLabel: String,
    accessibilityIdentifier: String? = nil,
    @ViewBuilder menuContent: @escaping () -> MenuContent
  ) {
    self.label = label
    self.value = value
    self.state = state
    self.accessibilityLabel = accessibilityLabel
    self.accessibilityIdentifier = accessibilityIdentifier
    self.menuContent = menuContent
  }

  var body: some View {
    Menu {
      menuContent()
    } label: {
      pillBody
    }
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .buttonStyle(AgentsConfigPillButtonStyle(state: state))
    .fixedSize(horizontal: true, vertical: false)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue(value ?? state.accessibilityValue)
    .accessibilityHint(state.accessibilityValue)
    .applyAgentsConfigPillIdentifier(accessibilityIdentifier)
  }

  private var pillBody: some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      if state.hasLeadingPlus {
        Image(systemName: "plus")
          .scaledFont(.caption.weight(.semibold))
          .accessibilityHidden(true)
      }
      Text(label)
        .scaledFont(.caption.weight(.medium))
        .lineLimit(1)
        .truncationMode(.tail)
      Image(systemName: "chevron.down")
        .scaledFont(.caption2.weight(.medium))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .accessibilityHidden(true)
    }
  }
}

private struct AgentsConfigPillButtonStyle: ButtonStyle {
  let state: AgentsConfigPillState

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(HarnessMonitorTheme.ink)
      .padding(.horizontal, HarnessMonitorTheme.spacingMD)
      .padding(.vertical, HarnessMonitorTheme.spacingXS)
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(
            HarnessMonitorTheme.ink.opacity(
              state.fillOpacity + (configuration.isPressed ? 0.06 : 0)
            )
          )
      )
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(
            HarnessMonitorTheme.controlBorder.opacity(state.strokeOpacity),
            lineWidth: 1
          )
      )
      .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
  }
}

extension View {
  @ViewBuilder
  fileprivate func applyAgentsConfigPillIdentifier(_ identifier: String?) -> some View {
    if let identifier {
      self.accessibilityIdentifier(identifier)
    } else {
      self
    }
  }
}

struct AgentsConfigPillFlow: Layout {
  let spacing: CGFloat
  let lineSpacing: CGFloat

  init(spacing: CGFloat = 8, lineSpacing: CGFloat = 8) {
    self.spacing = spacing
    self.lineSpacing = lineSpacing
  }

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) -> CGSize {
    let maxWidth = proposal.width ?? .infinity
    var totalHeight: CGFloat = 0
    var lineWidth: CGFloat = 0
    var lineHeight: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      let nextWidth = lineWidth + size.width + (lineWidth > 0 ? spacing : 0)
      if nextWidth > maxWidth, lineWidth > 0 {
        totalHeight += lineHeight + lineSpacing
        lineWidth = size.width
        lineHeight = size.height
      } else {
        lineWidth = nextWidth
        lineHeight = max(lineHeight, size.height)
      }
    }
    totalHeight += lineHeight
    return CGSize(
      width: maxWidth.isFinite ? maxWidth : lineWidth,
      height: totalHeight
    )
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    var x = bounds.minX
    var y = bounds.minY
    var lineHeight: CGFloat = 0
    let maxWidth = bounds.width
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x - bounds.minX + size.width > maxWidth, x > bounds.minX {
        x = bounds.minX
        y += lineHeight + lineSpacing
        lineHeight = 0
      }
      subview.place(
        at: CGPoint(x: x, y: y),
        anchor: .topLeading,
        proposal: ProposedViewSize(width: size.width, height: size.height)
      )
      x += size.width + spacing
      lineHeight = max(lineHeight, size.height)
    }
  }
}
