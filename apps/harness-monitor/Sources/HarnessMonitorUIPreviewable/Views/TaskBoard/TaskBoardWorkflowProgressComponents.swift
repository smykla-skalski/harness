import HarnessMonitorKit
import SwiftUI

private struct TaskBoardWorkflowRowButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(HarnessMonitorTheme.ink)
      .opacity(configuration.isPressed ? 0.72 : 1)
      .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
  }
}

private struct TaskBoardWorkflowBadgeChrome: ViewModifier {
  let tint: Color
  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency
  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast

  private var fillOpacity: Double {
    if reduceTransparency {
      return colorSchemeContrast == .increased ? 0.34 : 0.26
    }
    return colorSchemeContrast == .increased ? 0.24 : 0.16
  }

  func body(content: Content) -> some View {
    content.background {
      Capsule()
        .fill(tint.opacity(fillOpacity))
    }
  }
}

struct TaskBoardWorkflowStatusPill: View {
  let title: String
  let systemImage: String
  let tint: Color
  @Environment(\.fontScale)
  private var fontScale

  var body: some View {
    Label(title, systemImage: systemImage)
      .font(HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale))
      .foregroundStyle(tint)
      .fixedSize()
      .padding(.horizontal, HarnessMonitorTheme.pillPaddingH)
      .padding(.vertical, HarnessMonitorTheme.pillPaddingV)
      .modifier(TaskBoardWorkflowBadgeChrome(tint: tint))
      .accessibilityElement(children: .combine)
      .accessibilityLabel(title)
  }
}

struct TaskBoardWorkflowSectionHeader<Accessory: View>: View {
  let title: String
  let systemImage: String
  let accessory: Accessory
  @Environment(\.fontScale)
  private var fontScale

  init(
    title: String,
    systemImage: String,
    @ViewBuilder accessory: () -> Accessory
  ) {
    self.title = title
    self.systemImage = systemImage
    self.accessory = accessory()
  }

  var body: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingXS) {
      Label(title, systemImage: systemImage)
        .font(HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale))
        .fixedSize()
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      accessory
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

extension TaskBoardWorkflowSectionHeader where Accessory == EmptyView {
  init(title: String, systemImage: String) {
    self.init(title: title, systemImage: systemImage) {
      EmptyView()
    }
  }
}

struct TaskBoardWorkflowMetadataCard: View {
  let provenance: TaskBoardReviewProvenance

  var body: some View {
    VStack(spacing: 0) {
      ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
        metadataRow(row)
        if index != rows.indices.last {
          Divider()
        }
      }
    }
    .taskBoardWorkflowCard()
  }

  private var rows: [MetadataRow] {
    var rows: [MetadataRow] = []
    if let repository = provenance.repository,
      let pullRequestNumber = provenance.pullRequestNumber
    {
      rows.append(
        .init(
          label: "Pull request",
          value: "\(repository)#\(pullRequestNumber)",
          destination: githubURL(path: "/\(repository)/pull/\(pullRequestNumber)")
        )
      )
    }
    rows.append(
      .init(
        label: "Runtime",
        value: provenance.actualRuntime ?? provenance.requestedRuntime
      )
    )
    if let model = provenance.model {
      rows.append(.init(label: "Model", value: model))
    }
    if let revision = provenance.headRevision {
      rows.append(
        .init(
          label: "Revision",
          value: revision,
          monospaced: true,
          destination: provenance.repository.flatMap {
            githubURL(path: "/\($0)/commit/\(revision)")
          }
        )
      )
    }
    if let executionID = provenance.executionID {
      rows.append(.init(label: "Execution", value: executionID, monospaced: true))
    }
    rows.append(
      .init(label: "Started", value: provenance.startedAt.taskBoardReviewDisplayTimestamp)
    )
    if let finishedAt = provenance.finishedAt {
      rows.append(
        .init(label: "Finished", value: finishedAt.taskBoardReviewDisplayTimestamp)
      )
    }
    return rows
  }

  private func metadataRow(_ row: MetadataRow) -> some View {
    TaskBoardWorkflowValueRow(
      label: row.label,
      value: row.value,
      monospaced: row.monospaced,
      destination: row.destination
    )
  }

  private struct MetadataRow {
    let label: String
    let value: String
    var monospaced = false
    var destination: URL?
  }
}

struct TaskBoardWorkflowTriageCard: View {
  let dependencyChange: String
  let safetyAssessment: String
  let requiredTools: [String]

  var body: some View {
    VStack(spacing: 0) {
      TaskBoardWorkflowValueRow(
        label: "Dependency",
        value: dependencyChange
      )
      Divider()
      TaskBoardWorkflowValueRow(
        label: "Safety assessment",
        value: safetyAssessment.withoutTrailingPeriod
      )
      if !requiredTools.isEmpty {
        Divider()
        TaskBoardWorkflowValueRow(
          label: "Required tools",
          value: requiredTools.joined(separator: " · ")
        )
      }
    }
    .taskBoardWorkflowCard()
  }
}

struct TaskBoardWorkflowChecksCard: View {
  let checks: [TaskBoardDependencyCheck]
  @Environment(\.fontScale)
  private var fontScale

  var body: some View {
    VStack(spacing: 0) {
      ForEach(Array(checks.enumerated()), id: \.offset) { index, check in
        Group {
          if let value = check.detailsUrl, let url = URL(string: value) {
            Link(destination: url) {
              checkRow(check, showsExternalLink: true)
            }
            .buttonStyle(TaskBoardWorkflowRowButtonStyle())
            .help("Open check")
          } else {
            checkRow(check, showsExternalLink: false)
          }
        }
        .padding(HarnessMonitorTheme.spacingSM)
        if index != checks.indices.last {
          Divider()
        }
      }
    }
    .taskBoardWorkflowCard()
  }

  private func checkRow(
    _ check: TaskBoardDependencyCheck,
    showsExternalLink: Bool
  ) -> some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: check.state.systemImage)
        .foregroundStyle(check.state.tint)
        .accessibilityHidden(true)
      Text(check.name)
        .foregroundStyle(HarnessMonitorTheme.ink)
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      Text(check.state.displayTitle)
        .foregroundStyle(check.state.tint)
      if showsExternalLink {
        Image(systemName: "arrow.up.right.square")
          .foregroundStyle(HarnessMonitorTheme.accent.opacity(0.72))
          .accessibilityHidden(true)
      }
    }
    .font(HarnessMonitorTextSize.scaledFont(.caption, by: fontScale))
    .contentShape(.rect)
  }
}

struct TaskBoardWorkflowStepsCard: View {
  let steps: [TaskBoardDependencyTriageStep]
  @State private var selectedStep: TaskBoardWorkflowStepSelection?
  @Environment(\.fontScale)
  private var fontScale

  var body: some View {
    let sorted = steps.sorted(by: { $0.order < $1.order })
    VStack(spacing: 0) {
      ForEach(Array(sorted.enumerated()), id: \.element.order) { index, step in
        Button {
          selectedStep = TaskBoardWorkflowStepSelection(step: step)
        } label: {
          HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
            Text("\(step.order)")
              .font(captionSemibold.monospacedDigit())
              .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
              .frame(width: 18, alignment: .center)
            Text(step.action.taskBoardDisplayTitle)
              .font(captionSemibold)
              .lineLimit(1)
              .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: HarnessMonitorTheme.spacingSM)
            Text(step.reason.withoutTrailingPeriod)
              .font(captionFont)
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              .lineLimit(1)
              .truncationMode(.tail)
              .multilineTextAlignment(.trailing)
              .frame(maxWidth: .infinity, alignment: .trailing)
            Image(systemName: "chevron.right")
              .font(captionFont)
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              .accessibilityHidden(true)
          }
          .contentShape(.rect)
        }
        .buttonStyle(TaskBoardWorkflowRowButtonStyle())
        .help("Show step details")
        .padding(HarnessMonitorTheme.spacingSM)
        .frame(maxWidth: .infinity, alignment: .leading)
        if index != sorted.indices.last {
          Divider()
        }
      }
    }
    .taskBoardWorkflowCard()
    .sheet(item: $selectedStep) { selection in
      TaskBoardWorkflowStepDetailSheet(step: selection.step)
    }
  }

  private var captionFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }

  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }
}

struct TaskBoardWorkflowAttemptsCard: View {
  let attempts: [TaskBoardWorkflowAttemptProgress]
  @State private var selectedAttempt: TaskBoardWorkflowAttemptSelection?
  @Environment(\.fontScale)
  private var fontScale

  var body: some View {
    VStack(spacing: 0) {
      ForEach(Array(attempts.enumerated()), id: \.offset) { index, attempt in
        Button {
          selectedAttempt = TaskBoardWorkflowAttemptSelection(attempt: attempt)
        } label: {
          HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
            Image(systemName: attempt.state.systemImage)
              .foregroundStyle(attempt.state.tint)
              .accessibilityHidden(true)
            Text(attempt.actionKey.taskBoardDisplayTitle)
              .font(captionSemibold)
              .lineLimit(1)
            Spacer(minLength: HarnessMonitorTheme.spacingSM)
            Text(attempt.runtimeSummary)
              .font(captionFont)
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              .lineLimit(1)
              .truncationMode(.middle)
              .multilineTextAlignment(.trailing)
            Text(attempt.state.displayTitle)
              .font(captionFont)
              .foregroundStyle(attempt.state.tint)
              .lineLimit(1)
            Image(systemName: "chevron.right")
              .font(captionFont)
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              .accessibilityHidden(true)
          }
          .contentShape(.rect)
        }
        .buttonStyle(TaskBoardWorkflowRowButtonStyle())
        .help("Show attempt details")
        .padding(HarnessMonitorTheme.spacingSM)
        .frame(maxWidth: .infinity, alignment: .leading)
        if index != attempts.indices.last {
          Divider()
        }
      }
    }
    .taskBoardWorkflowCard()
    .sheet(item: $selectedAttempt) { selection in
      TaskBoardWorkflowAttemptDetailSheet(attempt: selection.attempt)
    }
  }

  private var captionFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }

  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }
}

struct TaskBoardWorkflowValueRow: View {
  let label: String
  let value: String
  var monospaced = false
  var destination: URL?
  @Environment(\.fontScale)
  private var fontScale

  var body: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
      Text(label)
        .font(captionFont)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      if let destination {
        Link(destination: destination) {
          valueText
        }
        .foregroundStyle(HarnessMonitorTheme.accent.opacity(0.72))
      } else {
        valueText
          .foregroundStyle(HarnessMonitorTheme.ink)
          .textSelection(.enabled)
      }
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingSM)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
  }

  private var valueText: some View {
    Text(value)
      .font(monospaced ? captionFont.monospaced() : captionSemibold)
      .lineLimit(1)
      .truncationMode(monospaced ? .middle : .tail)
      .multilineTextAlignment(.trailing)
      .help(value)
  }

  private var captionFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }

  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }
}

extension View {
  fileprivate func taskBoardWorkflowCard() -> some View {
    frame(maxWidth: .infinity, alignment: .leading)
      .background(HarnessMonitorTheme.ink.opacity(0.04), in: .rect(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(HarnessMonitorTheme.ink.opacity(0.1))
      }
  }
}

private func githubURL(path: String) -> URL? {
  var components = URLComponents()
  components.scheme = "https"
  components.host = "github.com"
  components.path = path
  return components.url
}

extension String {
  var withoutTrailingPeriod: String {
    var prose = trimmingCharacters(in: .whitespacesAndNewlines)
    while prose.hasSuffix(".") {
      prose.removeLast()
      prose = prose.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return prose
  }
}

extension TaskBoardWorkflowAttemptProgress {
  fileprivate var runtimeSummary: String {
    [runtime, model].compactMap(\.self).joined(separator: " · ")
  }
}
