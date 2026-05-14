import HarnessMonitorKit
import SwiftUI

/// Fold-out validation panel rendered under the canvas top bar. Lists every
/// resolved issue (daemon + local) with a severity icon, code, message, and a
/// focus button that selects the offending component. Stays collapsed by
/// default to keep the canvas chrome thin; auto-discloses the count badge so
/// the user can see at a glance whether the graph is clean.
struct PolicyCanvasValidationPanel: View {
  let viewModel: PolicyCanvasViewModel
  let focus: @MainActor (PolicyCanvasResolvedIssue) -> Void
  @State private var isExpanded: Bool = false

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      content
        .padding(.top, 6)
    } label: {
      header
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(Color(red: 0.05, green: 0.06, blue: 0.09).opacity(0.96))
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(.white.opacity(0.06))
        .frame(height: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasValidationPanel)
  }

  @ViewBuilder private var content: some View {
    let issues = viewModel.allValidationIssues
    if issues.isEmpty {
      Text("No validation issues detected")
        .scaledFont(.caption)
        .foregroundStyle(.white.opacity(0.78))
        .padding(.vertical, 4)
        .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasValidationEmpty)
    } else {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(issues) { issue in
          PolicyCanvasValidationRow(issue: issue, focus: focus)
        }
      }
    }
  }

  private var header: some View {
    let issues = viewModel.allValidationIssues
    let errorCount = issues.filter { $0.severity == .error }.count
    let warningCount = issues.filter { $0.severity == .warning }.count
    return HStack(spacing: 10) {
      Label(
        labelTitle(errorCount: errorCount, warningCount: warningCount),
        systemImage: headerSystemImage(errorCount: errorCount)
      )
      .scaledFont(.caption.weight(.semibold))
      .foregroundStyle(headerTone(errorCount: errorCount, warningCount: warningCount))

      Spacer(minLength: 0)
    }
    .contentShape(Rectangle())
    .accessibilityLabel(
      labelTitle(errorCount: errorCount, warningCount: warningCount)
    )
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasValidationToggle)
  }

  private func labelTitle(errorCount: Int, warningCount: Int) -> String {
    if errorCount == 0 && warningCount == 0 {
      return "Validation - no issues"
    }
    var parts: [String] = []
    if errorCount > 0 {
      parts.append("\(errorCount) error\(errorCount == 1 ? "" : "s")")
    }
    if warningCount > 0 {
      parts.append("\(warningCount) warning\(warningCount == 1 ? "" : "s")")
    }
    return "Validation - \(parts.joined(separator: ", "))"
  }

  private func headerSystemImage(errorCount: Int) -> String {
    errorCount > 0
      ? PolicyCanvasIssueSeverity.error.systemImage
      : "checkmark.circle"
  }

  private func headerTone(errorCount: Int, warningCount: Int) -> Color {
    if errorCount > 0 {
      return PolicyCanvasIssueSeverity.error.accentColor
    }
    if warningCount > 0 {
      return PolicyCanvasIssueSeverity.warning.accentColor
    }
    return .white.opacity(0.82)
  }
}

private struct PolicyCanvasValidationRow: View {
  let issue: PolicyCanvasResolvedIssue
  let focus: @MainActor (PolicyCanvasResolvedIssue) -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: issue.severity.systemImage)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(issue.severity.accentColor)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(issue.issue.code)
          .scaledFont(.caption.weight(.semibold))
          .foregroundStyle(.white)
          .lineLimit(1)

        Text(issue.issue.message)
          .scaledFont(.caption)
          .foregroundStyle(.white.opacity(0.82))
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 0)

      if issue.focusSelection != nil {
        Button {
          focus(issue)
        } label: {
          Label("Open", systemImage: "scope")
            .scaledFont(.caption.weight(.semibold))
            .labelStyle(.titleAndIcon)
        }
        .harnessPlainButtonStyle()
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.white.opacity(0.10), in: Capsule())
        .overlay {
          Capsule()
            .stroke(.white.opacity(0.20), lineWidth: 1)
        }
        .accessibilityLabel("Focus \(issue.issue.code)")
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.policyCanvasValidationFocusButton(issue.id)
        )
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    .overlay {
      RoundedRectangle(cornerRadius: 6)
        .stroke(.white.opacity(0.08), lineWidth: 1)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(issue.severity.displayLabel) \(issue.issue.code) \(issue.issue.message)"
    )
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.policyCanvasValidationRow(issue.id)
    )
  }
}
