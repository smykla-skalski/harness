import HarnessMonitorKit
import SwiftUI

public struct HeuristicIssueCardView: View {
  public let issue: ObserverIssueSummary

  public init(issue: ObserverIssueSummary) {
    self.issue = issue
  }

  private var severityTint: Color {
    switch issue.severity.lowercased() {
    case "critical", "high", "error":
      HarnessMonitorTheme.danger
    case "warn", "warning", "medium":
      HarnessMonitorTheme.caution
    default:
      HarnessMonitorTheme.secondaryInk
    }
  }

  private var categoryLabel: String {
    issue.category.isEmpty ? "uncategorised" : issue.category
  }

  private var occurrenceLabel: String? {
    guard let count = issue.occurrenceCount, count > 1 else { return nil }
    return "×\(count)"
  }

  private var rangeLabel: String? {
    switch (issue.firstSeenLine, issue.lastSeenLine) {
    case (let first?, let last?) where first != last:
      return "L\(first)-\(last)"
    case (let first?, _):
      return "L\(first)"
    case (_, let last?):
      return "L\(last)"
    default:
      return nil
    }
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.itemSpacing) {
        Text(issue.code)
          .scaledFont(.system(.subheadline, design: .monospaced, weight: .semibold))
          .foregroundStyle(severityTint)
        Text(categoryLabel)
          .scaledFont(.caption2)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        Spacer(minLength: 0)
        if let occurrenceLabel {
          Text(occurrenceLabel)
            .scaledFont(.caption.monospacedDigit())
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
        if let rangeLabel {
          Text(rangeLabel)
            .scaledFont(.caption.monospacedDigit())
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
      }
      Text(issue.summary)
        .scaledFont(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
      if let excerpt = issue.evidenceExcerpt, !excerpt.isEmpty {
        Text(excerpt)
          .scaledFont(.caption.monospaced())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(3)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(HarnessMonitorTheme.cardPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .fill(severityTint.opacity(0.08))
    }
    .overlay {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .stroke(severityTint.opacity(0.35), lineWidth: 1)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Text("\(issue.code) \(issue.severity)"))
    .accessibilityValue(Text(issue.summary))
    .accessibilityIdentifier(HarnessMonitorAccessibility.heuristicIssueCard(issue.code))
  }
}

public struct SessionCockpitHeuristicIssuesSection: View {
  public let issues: [ObserverIssueSummary]

  public init(issues: [ObserverIssueSummary]) {
    self.issues = issues
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      Text("Heuristic Issues")
        .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      LazyVStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
        ForEach(issues) { issue in
          HeuristicIssueCardView(issue: issue)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
