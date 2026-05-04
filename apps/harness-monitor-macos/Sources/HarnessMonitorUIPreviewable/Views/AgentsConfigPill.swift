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
  let state: AgentsConfigPillState
  let accessibilityLabel: String
  let accessibilityIdentifier: String?
  @ViewBuilder let menuContent: () -> MenuContent

  init(
    label: String,
    state: AgentsConfigPillState,
    accessibilityLabel: String,
    accessibilityIdentifier: String? = nil,
    @ViewBuilder menuContent: @escaping () -> MenuContent
  ) {
    self.label = label
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
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize(horizontal: true, vertical: false)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue(state.accessibilityValue)
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
    .foregroundStyle(HarnessMonitorTheme.ink)
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .padding(.vertical, HarnessMonitorTheme.spacingXS)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(HarnessMonitorTheme.ink.opacity(state.fillOpacity))
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
