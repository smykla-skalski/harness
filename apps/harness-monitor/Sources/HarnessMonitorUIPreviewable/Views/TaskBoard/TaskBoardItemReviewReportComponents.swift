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
  var requestedRuntime: String
  var actualRuntime: String?
  var model: String?
  var headRevision: String?
  var startedAt: String
  var finishedAt: String?
}

private struct TaskBoardReviewMetadataRow: Identifiable {
  let label: String
  let value: String
  var monospaced = false
  var destination: URL?

  var id: String { label }
}

private struct TaskBoardReviewBadgeChrome: ViewModifier {
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

extension View {
  fileprivate func taskBoardReviewBadgePadding() -> some View {
    padding(.horizontal, HarnessMonitorTheme.pillPaddingH)
      .padding(.vertical, HarnessMonitorTheme.pillPaddingV)
  }

  fileprivate func taskBoardReviewBadgeChrome(tint: Color) -> some View {
    modifier(TaskBoardReviewBadgeChrome(tint: tint))
  }
}

struct TaskBoardReviewSectionHeader<Accessory: View>: View {
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

extension TaskBoardReviewSectionHeader where Accessory == EmptyView {
  init(title: String, systemImage: String) {
    self.init(title: title, systemImage: systemImage) {
      EmptyView()
    }
  }
}

struct TaskBoardReviewMetadataCard: View {
  let provenance: TaskBoardReviewProvenance
  @State private var showsDetails: Bool
  @Environment(\.fontScale)
  private var fontScale

  init(
    provenance: TaskBoardReviewProvenance,
    initiallyShowsDetails: Bool = false
  ) {
    self.provenance = provenance
    _showsDetails = State(initialValue: initiallyShowsDetails)
  }

  private var captionFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }

  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  var body: some View {
    VStack(spacing: 0) {
      ForEach(visibleRows) { row in
        TaskBoardOperationsFormRow(
          row.label,
          showsSeparator: false,
          verticalPadding: HarnessMonitorTheme.spacingSM,
          contentMaxWidth: nil,
          minHeight: nil
        ) {
          metadataValue(row)
        }
        if row.id != visibleRows.last?.id {
          Divider()
        }
      }
      Divider()
      TaskBoardReviewDisclosureButton(
        collapsedTitle: "Show details",
        expandedTitle: "Hide details",
        isExpanded: $showsDetails
      )
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingSM)
    .environment(\.taskBoardOperationsRowLabelFont, captionFont)
    .environment(
      \.taskBoardOperationsRowLabelWidth,
      124 * min(fontScale, 1.3)
    )
    .background(HarnessMonitorTheme.ink.opacity(0.04), in: .rect(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(HarnessMonitorTheme.ink.opacity(0.1))
    }
  }

  private var visibleRows: [TaskBoardReviewMetadataRow] {
    primaryRows + (showsDetails ? detailRows : [])
  }

  private var primaryRows: [TaskBoardReviewMetadataRow] {
    var result: [TaskBoardReviewMetadataRow] = []
    if let repository = provenance.repository,
      let pullRequestNumber = provenance.pullRequestNumber
    {
      result.append(
        .init(
          label: "Pull request",
          value: "\(repository)#\(pullRequestNumber)",
          destination: TaskBoardReviewGitHubLinks.pullRequest(
            repository: repository,
            number: pullRequestNumber
          )
        )
      )
    }
    result.append(
      .init(
        label: "Runtime",
        value: provenance.actualRuntime ?? provenance.requestedRuntime
      )
    )
    if let model = provenance.model {
      result.append(.init(label: "Model", value: model))
    }
    if let headRevision = provenance.headRevision {
      result.append(
        .init(
          label: "Revision",
          value: headRevision,
          monospaced: true,
          destination: TaskBoardReviewGitHubLinks.revision(
            repository: provenance.repository,
            revision: headRevision
          )
        )
      )
    }
    return result
  }

  private var detailRows: [TaskBoardReviewMetadataRow] {
    var result = [
      TaskBoardReviewMetadataRow(
        label: "Requested runtime",
        value: provenance.requestedRuntime
      )
    ]
    if let actualRuntime = provenance.actualRuntime {
      result.append(.init(label: "Actual runtime", value: actualRuntime))
    }
    if let executionID = provenance.executionID {
      result.append(.init(label: "Execution", value: executionID, monospaced: true))
    }
    result.append(
      .init(label: "Started", value: provenance.startedAt.taskBoardReviewDisplayTimestamp)
    )
    if let finishedAt = provenance.finishedAt {
      result.append(.init(label: "Finished", value: finishedAt.taskBoardReviewDisplayTimestamp))
    }
    return result
  }

  @ViewBuilder
  private func metadataValue(_ row: TaskBoardReviewMetadataRow) -> some View {
    if let destination = row.destination {
      Link(destination: destination) {
        metadataText(row)
      }
      .foregroundStyle(HarnessMonitorTheme.accent)
      .help("Open \(row.label.lowercased()) on GitHub")
    } else {
      metadataText(row)
        .textSelection(.enabled)
    }
  }

  private func metadataText(_ row: TaskBoardReviewMetadataRow) -> some View {
    Text(row.value)
      .font(row.monospaced ? captionFont.monospaced() : captionSemibold)
      .lineLimit(row.monospaced ? 1 : nil)
      .truncationMode(.middle)
      .multilineTextAlignment(.trailing)
      .help(row.value)
  }
}

struct TaskBoardReviewPill: View {
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
      .taskBoardReviewBadgePadding()
      .taskBoardReviewBadgeChrome(tint: tint)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(title)
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
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
      accessory
    }
    .foregroundStyle(HarnessMonitorTheme.ink)
    .padding(HarnessMonitorTheme.spacingSM)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(tint.opacity(0.08), in: .rect(cornerRadius: 8))
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

}
