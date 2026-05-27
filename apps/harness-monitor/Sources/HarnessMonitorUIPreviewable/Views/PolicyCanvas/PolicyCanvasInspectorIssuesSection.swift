import HarnessMonitorKit
import SwiftUI

/// Inspector-scoped issue listing for the currently selected component.
/// Rendered only when at least one issue targets the selection so the
/// inspector stays compact on clean graphs; mirrors the chrome panel rows in
/// severity and message but without the focus button (selection is already
/// the component being inspected).
struct PolicyCanvasInspectorIssuesSection: View {
  let viewModel: PolicyCanvasViewModel
  let selection: PolicyCanvasSelection

  var body: some View {
    let issues = viewModel.resolvedIssues(for: selection)
    Group {
      if !issues.isEmpty {
        PolicyCanvasInspectorSection(title: "Issues") {
          ForEach(issues) { resolved in
            row(for: resolved)
          }
        }
      }
    }
  }

  private func row(for resolved: PolicyCanvasResolvedIssue) -> some View {
    let presentation = viewModel.issuePresentation(for: resolved)
    return HStack(alignment: .top, spacing: 8) {
      Image(systemName: resolved.severity.systemImage)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(resolved.severity.accentColor)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(presentation.title)
          .scaledFont(.caption.weight(.semibold))
          .foregroundStyle(.white)

        Text(presentation.detail)
          .scaledFont(.caption)
          .foregroundStyle(.white.opacity(0.82))
          .fixedSize(horizontal: false, vertical: true)

        if let targetSummary = presentation.targetSummary {
          Text(targetSummary)
            .scaledFont(.caption2.weight(.medium))
            .foregroundStyle(.white.opacity(0.66))
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(resolved.severity.displayLabel) \(presentation.title) \(presentation.detail)"
    )
  }
}
