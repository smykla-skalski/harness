import SwiftUI

enum SessionCockpitLayout {
  static let laneCardHeight: CGFloat = 116
  static let laneCardFootprint: CGFloat = laneCardHeight + (HarnessMonitorTheme.cardPadding * 2)
  static let statusHeaderClearance: CGFloat = HarnessMonitorTheme.spacingXS
}

struct SessionCockpitEmptyStateRow: View {
  static let baseFont: Font = .system(.callout, design: .rounded, weight: .medium)
  static let usesSecondaryForeground = true

  enum Section: String, Sendable {
    case tasks
    case agents
    case signals
    case timeline

    var message: String {
      switch self {
      case .tasks:
        "No tasks yet"
      case .agents:
        "No agents yet"
      case .signals:
        "No signals yet"
      case .timeline:
        "No activity yet"
      }
    }

    var accessibilityIdentifier: String {
      HarnessMonitorAccessibility.sessionEmptyState(rawValue)
    }
  }

  let section: Section

  var body: some View {
    HStack(spacing: 0) {
      messageLabel
      Spacer(minLength: 0)
    }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Text(section.message))
      .accessibilityIdentifier(section.accessibilityIdentifier)
  }

  @ViewBuilder
  private var messageLabel: some View {
    if Self.usesSecondaryForeground {
      Text(section.message)
        .scaledFont(Self.baseFont)
        .foregroundStyle(.secondary)
    } else {
      Text(section.message)
        .scaledFont(Self.baseFont)
    }
  }
}
