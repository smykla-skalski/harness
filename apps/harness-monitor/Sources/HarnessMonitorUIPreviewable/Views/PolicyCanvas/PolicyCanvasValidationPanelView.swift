import HarnessMonitorKit
import SwiftUI

typealias PolicyCanvasIssueFocusAction = @MainActor (PolicyCanvasResolvedIssue) -> Void

/// Validation surface rendered under the canvas top bar. Lists every resolved
/// issue with repair-oriented copy and a direct jump back to the affected
/// canvas step.
struct PolicyCanvasValidationPanel: View {
  let viewModel: PolicyCanvasViewModel
  let focus: PolicyCanvasIssueFocusAction

  var body: some View {
    let issues = viewModel.allValidationIssues
    if !issues.isEmpty {
      let errors = issues.filter { $0.severity == .error }
      let warnings = issues.filter { $0.severity == .warning }
      VStack(alignment: .leading, spacing: 12) {
        header(errorCount: errors.count, warningCount: warnings.count)

        if !errors.isEmpty {
          issueSection(
            title: "Fix before promotion",
            issues: errors
          )
        }

        if !warnings.isEmpty {
          issueSection(
            title: errors.isEmpty ? "Warnings to review" : "Then review warnings",
            issues: warnings
          )
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .background(Color(red: 0.05, green: 0.06, blue: 0.09).opacity(0.96))
      .overlay(alignment: .bottom) {
        Rectangle()
          .fill(.white.opacity(0.06))
          .frame(height: 1)
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasValidationPanel)
    }
  }

  private func header(errorCount: Int, warningCount: Int) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 10) {
        Label(
          headerTitle(errorCount: errorCount, warningCount: warningCount),
          systemImage: headerSystemImage(errorCount: errorCount)
        )
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(headerTone(errorCount: errorCount, warningCount: warningCount))

        Spacer(minLength: 0)
      }

      Text(headerSubtitle(errorCount: errorCount, warningCount: warningCount))
        .scaledFont(.caption)
        .foregroundStyle(.white.opacity(0.76))
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityLabel(headerTitle(errorCount: errorCount, warningCount: warningCount))
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasValidationToggle)
  }

  private func issueSection(
    title: String,
    issues: [PolicyCanvasResolvedIssue]
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .scaledFont(.caption.weight(.bold))
        .foregroundStyle(.white.opacity(0.74))
        .textCase(.uppercase)

      VStack(alignment: .leading, spacing: 8) {
        ForEach(issues) { issue in
          PolicyCanvasValidationRow(
            viewModel: viewModel,
            issue: issue,
            focus: focus
          )
        }
      }
    }
  }

  private func headerTitle(errorCount: Int, warningCount: Int) -> String {
    if errorCount > 0 {
      var title = "Fix \(errorCount) issue\(errorCount == 1 ? "" : "s") before promotion"
      if warningCount > 0 {
        title += " and review \(warningCount) warning\(warningCount == 1 ? "" : "s")"
      }
      return title
    }
    return "Review \(warningCount) warning\(warningCount == 1 ? "" : "s") before promotion"
  }

  private func headerSubtitle(errorCount: Int, warningCount: Int) -> String {
    if errorCount > 0 {
      return
        "Each issue can highlight the affected step on the canvas so you can repair it without hunting through the graph."
    }
    if warningCount > 0 {
      return "Warnings do not block editing, but they are worth reviewing before you promote this policy."
    }
    return "No issues to review."
  }

  private func headerSystemImage(errorCount: Int) -> String {
    errorCount > 0
      ? PolicyCanvasIssueSeverity.error.systemImage
      : "exclamationmark.circle.fill"
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
  let viewModel: PolicyCanvasViewModel
  let issue: PolicyCanvasResolvedIssue
  let focus: @MainActor (PolicyCanvasResolvedIssue) -> Void

  var body: some View {
    let presentation = viewModel.issuePresentation(for: issue)
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: issue.severity.systemImage)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(issue.severity.accentColor)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 6) {
        Text(presentation.title)
          .scaledFont(.callout.weight(.semibold))
          .foregroundStyle(.white)
          .fixedSize(horizontal: false, vertical: true)

        Text(presentation.detail)
          .scaledFont(.caption)
          .foregroundStyle(.white.opacity(0.82))
          .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 8) {
          Text(presentation.codeLabel)
            .scaledFont(.caption2.weight(.semibold))
            .foregroundStyle(.white.opacity(0.72))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.white.opacity(0.08), in: Capsule())

          if let targetSummary = presentation.targetSummary {
            Text(targetSummary)
              .scaledFont(.caption.weight(.medium))
              .foregroundStyle(.white.opacity(0.72))
              .lineLimit(1)
          }
        }
      }

      Spacer(minLength: 0)

      if issue.focusSelection != nil {
        Button {
          focus(issue)
        } label: {
          Label("Show on canvas", systemImage: "scope")
            .scaledFont(.caption.weight(.semibold))
            .lineLimit(1)
        }
        .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
        .controlSize(.small)
        .accessibilityLabel(
          presentation.targetSummary.map { "Show \($0) on canvas" } ?? "Show issue on canvas"
        )
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.policyCanvasValidationFocusButton(issue.id)
        )
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 10)
    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(.white.opacity(0.08), lineWidth: 1)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(issue.severity.displayLabel) \(presentation.title). \(presentation.detail)"
    )
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.policyCanvasValidationRow(issue.id)
    )
  }
}
