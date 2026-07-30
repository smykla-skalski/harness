import HarnessMonitorKit
import SwiftUI

struct TaskBoardReviewFindingsSection: View {
  let findings: [TaskBoardReportOnlyReviewFinding]
  let repository: String
  let revision: String
  @Environment(\.fontScale)
  private var fontScale

  private var captionFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }

  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      TaskBoardReviewSectionHeader(
        title: "Findings",
        systemImage: "list.bullet.rectangle"
      ) {
        Text("\(findings.count)")
          .font(captionSemibold.monospacedDigit())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .fixedSize()
      }
      .padding(.horizontal, HarnessMonitorTheme.spacingMD)
      VStack(alignment: .leading, spacing: 0) {
        findingsContent
      }
      .fixedSize(horizontal: false, vertical: true)
      .background(HarnessMonitorTheme.ink.opacity(0.04), in: .rect(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(HarnessMonitorTheme.ink.opacity(0.1))
      }
      .clipShape(.rect(cornerRadius: 8))
    }
  }

  @ViewBuilder private var findingsContent: some View {
    if findings.isEmpty {
      Text("No actionable findings")
        .font(captionFont)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .padding(HarnessMonitorTheme.spacingMD)
    } else {
      ForEach(Array(findings.enumerated()), id: \.offset) { index, finding in
        findingRow(finding)
        if index != findings.indices.last {
          Divider()
        }
      }
    }
  }

  private func findingRow(_ finding: TaskBoardReportOnlyReviewFinding) -> some View {
    HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingMD) {
      Image(systemName: finding.severity.taskBoardSystemImage)
        .font(captionSemibold)
        .foregroundStyle(finding.severity.taskBoardTint)
        .padding(HarnessMonitorTheme.spacingXS)
        .background(
          finding.severity.taskBoardTint.opacity(0.16),
          in: .circle
        )
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        findingIdentity(finding)
        Text(finding.evidence)
          .font(captionFont)
          .foregroundStyle(HarnessMonitorTheme.ink.opacity(0.84))
          .lineSpacing(2)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(HarnessMonitorTheme.spacingMD)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func findingIdentity(
    _ finding: TaskBoardReportOnlyReviewFinding
  ) -> some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingXS) {
      Text(finding.severity.taskBoardTitle)
        .font(captionSemibold)
        .foregroundStyle(finding.severity.taskBoardTint)
        .fixedSize()
      Text("·")
        .font(captionFont)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .fixedSize()
        .accessibilityHidden(true)
      locationLink(finding.location)
    }
  }

  @ViewBuilder private func locationLink(
    _ location: TaskBoardReviewFindingLocation
  ) -> some View {
    let line = location.line.map { ":\($0)" } ?? ""
    let label = "\(location.path)\(line)"
    if let destination = TaskBoardReviewGitHubLinks.file(
      repository: repository,
      revision: revision,
      path: location.path,
      line: location.line
    ) {
      Link(destination: destination) {
        locationText(label)
      }
      .foregroundStyle(HarnessMonitorTheme.accent)
      .help("Open \(label) on GitHub")
    } else {
      locationText(label)
    }
  }

  private func locationText(_ label: String) -> some View {
    Text(label)
      .font(captionSemibold.monospaced())
      .lineLimit(1)
      .truncationMode(.middle)
      .fixedSize(horizontal: false, vertical: true)
      .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
      .clipped()
  }
}

extension TaskBoardReviewFindingSeverity {
  fileprivate var taskBoardSystemImage: String {
    switch self {
    case .critical:
      "exclamationmark.octagon.fill"
    case .high:
      "exclamationmark.triangle.fill"
    case .medium:
      "exclamationmark.circle.fill"
    case .low:
      "info.circle.fill"
    }
  }

  fileprivate var taskBoardTint: Color {
    switch self {
    case .critical, .high:
      HarnessMonitorTheme.danger
    case .medium:
      HarnessMonitorTheme.caution
    case .low:
      HarnessMonitorTheme.accent
    }
  }

  fileprivate var taskBoardTitle: String {
    rawValue.capitalized
  }
}
