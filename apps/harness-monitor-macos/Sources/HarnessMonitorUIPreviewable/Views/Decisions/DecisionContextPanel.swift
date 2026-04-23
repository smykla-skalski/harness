import HarnessMonitorKit
import SwiftUI

/// Context panel rendered inside the Decisions detail column.
public struct DecisionContextPanel: View {
  private let sections: [DecisionDetailViewModel.ContextSection]

  public init(sections: [DecisionDetailViewModel.ContextSection] = []) {
    self.sections = sections
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      if sections.isEmpty {
        SidebarEmptyState(
          title: "No Context Yet",
          systemImage: "doc.text.magnifyingglass",
          message: "Supervisor context will appear here when the decision includes extra details."
        )
      } else {
        ForEach(sections) { section in
          ContextSectionCard(section: section)
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.decisionContextPanel)
  }
}

private struct ContextSectionCard: View {
  let section: DecisionDetailViewModel.ContextSection

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text(section.title)
        .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
          Text(line)
            .scaledFont(.body)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
      }
    }
    .padding(HarnessMonitorTheme.cardPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .fill(HarnessMonitorTheme.ink.opacity(0.04))
    }
    .overlay {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .strokeBorder(HarnessMonitorTheme.controlBorder.opacity(0.32), lineWidth: 1)
    }
  }
}

#Preview("Decision Context — empty") {
  DecisionContextPanel()
    .frame(width: 420, height: 320)
}

#Preview("Decision Context — populated") {
  DecisionContextPanel(
    sections: [
      .init(title: "Snapshot", lines: ["agent=agent-7 idle=720s owner=leader"]),
      .init(
        title: "Related timeline",
        lines: ["signal.sent: 12:01", "reminder.sent: 12:04", "reply.missing: 12:12"]
      ),
    ]
  )
  .frame(width: 420, height: 320)
}
