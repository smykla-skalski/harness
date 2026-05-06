import HarnessMonitorKit
import SwiftUI

/// Context panel rendered inside the Decisions detail column.
public struct DecisionContextPanel: View {
  private let sections: [DecisionDetailViewModel.ContextSection]

  public init(sections: [DecisionDetailViewModel.ContextSection] = []) {
    self.sections = sections
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      if sections.isEmpty {
        emptyState
      } else {
        ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
          ContextSectionBlock(section: section)
          if index < sections.count - 1 {
            Divider()
          }
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.decisionContextPanel)
  }

  private var emptyState: some View {
    HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: "info.circle")
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        Text("No extra context yet")
          .scaledFont(.callout.weight(.semibold))
        Text(
          "This decision does not include additional notes yet. "
            + "Check the history or related workspace activity instead."
        )
        .scaledFont(.footnote)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(HarnessMonitorTheme.spacingMD)
    .background {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
        .fill(HarnessMonitorTheme.ink.opacity(0.04))
    }
  }
}

private struct ContextSectionBlock: View {
  let section: DecisionDetailViewModel.ContextSection

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text(section.title)
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
          Text(verbatim: line)
            .scaledFont(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
