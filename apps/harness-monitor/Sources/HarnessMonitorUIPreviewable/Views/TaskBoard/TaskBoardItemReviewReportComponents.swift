import HarnessMonitorKit
import SwiftUI

@MainActor private let reviewTimestampFormatter: ISO8601DateFormatter = {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime]
  return formatter
}()

@MainActor private let reviewFractionalFormatter: ISO8601DateFormatter = {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter
}()

struct TaskBoardReviewProvenance {
  var executionID: String?
  var repository: String?
  var pullRequestNumber: UInt64?
  var runtime: String
  var model: String?
  var headRevision: String?
  var startedAt: String
  var finishedAt: String?
}

struct TaskBoardReviewMetadataCard: View {
  let provenance: TaskBoardReviewProvenance
  @Environment(\.fontScale)
  private var fontScale

  private var captionFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }

  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      if let repository = provenance.repository,
        let pullRequestNumber = provenance.pullRequestNumber
      {
        metadataRow("Pull request", "\(repository) #\(pullRequestNumber)")
      }
      metadataRow("Runtime", provenance.runtime)
      if let model = provenance.model {
        metadataRow("Model", model)
      }
      if let headRevision = provenance.headRevision {
        metadataRow("Revision", headRevision, monospaced: true)
      }
      if let executionID = provenance.executionID {
        metadataRow("Execution", executionID, monospaced: true)
      }
      metadataRow("Started", provenance.startedAt.taskBoardReviewDisplayTimestamp)
      if let finishedAt = provenance.finishedAt {
        metadataRow("Finished", finishedAt.taskBoardReviewDisplayTimestamp)
      }
    }
    .padding(HarnessMonitorTheme.spacingSM)
    .background(HarnessMonitorTheme.ink.opacity(0.04), in: .rect(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(HarnessMonitorTheme.ink.opacity(0.1))
    }
  }

  private func metadataRow(
    _ label: String,
    _ value: String,
    monospaced: Bool = false
  ) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
        Text(label)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        Spacer(minLength: HarnessMonitorTheme.spacingSM)
        metadataValue(value, monospaced: monospaced)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(label)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        metadataValue(value, monospaced: monospaced)
      }
    }
    .font(captionFont)
  }

  @ViewBuilder
  private func metadataValue(_ value: String, monospaced: Bool) -> some View {
    if monospaced {
      Text(value)
        .font(captionFont.monospaced())
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
        .help(value)
    } else {
      Text(value)
        .font(captionSemibold)
        .multilineTextAlignment(.trailing)
        .textSelection(.enabled)
    }
  }
}

struct TaskBoardReviewStaleHeadCard: View {
  let reportHead: String
  let currentHead: String?
  @Environment(\.fontScale)
  private var fontScale

  private var captionFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }

  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Label("Report is for an older revision", systemImage: "exclamationmark.triangle.fill")
        .font(captionSemibold)
      if let currentHead {
        Text(
          "Reviewed \(reportHead.taskBoardShortRevision) · "
            + "Current \(currentHead.taskBoardShortRevision)"
        )
        .font(captionFont.monospaced())
        .textSelection(.enabled)
      }
    }
    .foregroundStyle(HarnessMonitorTheme.caution)
    .padding(HarnessMonitorTheme.spacingSM)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HarnessMonitorTheme.caution.opacity(0.12), in: .rect(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(HarnessMonitorTheme.caution.opacity(0.3))
    }
    .accessibilityLabel("Report is for an older pull request revision")
  }
}

struct TaskBoardReviewFindingsSection: View {
  let findings: [TaskBoardReportOnlyReviewFinding]
  @Environment(\.fontScale)
  private var fontScale

  private var captionFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }

  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        Label("Findings", systemImage: "list.bullet.rectangle")
          .font(captionSemibold)
        Text("\(findings.count)")
          .font(captionSemibold.monospacedDigit())
          .harnessPillPadding()
          .harnessContentPill(
            tint: findings.isEmpty ? HarnessMonitorTheme.success : Color.secondary
          )
      }
      if findings.isEmpty {
        Text("No actionable findings")
          .font(captionFont)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      } else {
        ForEach(Array(findings.enumerated()), id: \.offset) { _, finding in
          findingCard(finding)
        }
      }
    }
    .fixedSize(horizontal: false, vertical: true)
  }

  private func findingCard(_ finding: TaskBoardReportOnlyReviewFinding) -> some View {
    let line = finding.location.line.map { ":\($0)" } ?? ""
    let tint = finding.severity.taskBoardTint
    return VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
          severityPill(finding.severity)
          locationText(finding.location.path, line: line, singleLine: true)
        }
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
          severityPill(finding.severity)
          locationText(finding.location.path, line: line, singleLine: false)
        }
      }
      Text(finding.evidence)
        .font(captionFont)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(HarnessMonitorTheme.spacingSM)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HarnessMonitorTheme.ink.opacity(0.04), in: .rect(cornerRadius: 8))
    .overlay(alignment: .leading) {
      Rectangle()
        .fill(tint)
        .frame(width: 3)
    }
    .clipShape(.rect(cornerRadius: 8))
  }

  private func severityPill(_ severity: TaskBoardReviewFindingSeverity) -> some View {
    Label(severity.taskBoardTitle, systemImage: severity.taskBoardSystemImage)
      .font(captionSemibold)
      .foregroundStyle(severity.taskBoardTint)
      .harnessPillPadding()
      .harnessContentPill(tint: severity.taskBoardTint)
  }

  private func locationText(_ path: String, line: String, singleLine: Bool) -> some View {
    Text("\(path)\(line)")
      .font(captionSemibold.monospaced())
      .lineLimit(singleLine ? 1 : nil)
      .truncationMode(.middle)
      .textSelection(.enabled)
  }
}

struct TaskBoardReviewTextCard: View {
  let title: String
  let systemImage: String
  let content: String
  @Environment(\.fontScale)
  private var fontScale

  private var captionFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }

  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Label(title, systemImage: systemImage)
        .font(captionSemibold)
      Text(content)
        .font(captionFont)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(HarnessMonitorTheme.spacingSM)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HarnessMonitorTheme.ink.opacity(0.04), in: .rect(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(HarnessMonitorTheme.ink.opacity(0.1))
    }
  }
}

struct TaskBoardReviewStatusPill: View {
  let title: String
  let systemImage: String
  let tint: Color
  @Environment(\.fontScale)
  private var fontScale

  var body: some View {
    Label(title, systemImage: systemImage)
      .font(HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale))
      .foregroundStyle(tint)
      .harnessPillPadding()
      .harnessContentPill(tint: tint)
  }
}

struct TaskBoardReviewMessageCard<Accessory: View>: View {
  let icon: String
  let title: String
  let detail: String
  let tint: Color
  let accessory: Accessory
  @Environment(\.fontScale)
  private var fontScale

  init(
    icon: String,
    title: String,
    detail: String,
    tint: Color,
    @ViewBuilder accessory: () -> Accessory
  ) {
    self.icon = icon
    self.title = title
    self.detail = detail
    self.tint = tint
    self.accessory = accessory()
  }

  private var captionFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }

  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  var body: some View {
    HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: icon)
        .font(captionSemibold)
        .foregroundStyle(tint)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(captionSemibold)
        Text(detail)
          .font(captionFont)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
      accessory
    }
    .padding(HarnessMonitorTheme.spacingSM)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HarnessMonitorTheme.ink.opacity(0.04), in: .rect(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(tint.opacity(0.22))
    }
  }
}

extension TaskBoardReviewMessageCard where Accessory == EmptyView {
  init(icon: String, title: String, detail: String, tint: Color) {
    self.init(icon: icon, title: title, detail: detail, tint: tint) {
      EmptyView()
    }
  }
}

extension String {
  @MainActor fileprivate var taskBoardReviewDisplayTimestamp: String {
    let date =
      reviewFractionalFormatter.date(from: self)
      ?? reviewTimestampFormatter.date(from: self)
    guard let date else { return self }
    return date.formatted(date: .abbreviated, time: .shortened)
  }

  fileprivate var taskBoardShortRevision: String {
    String(prefix(8))
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
