import Foundation
import HarnessMonitorKit
import SwiftUI
import UniformTypeIdentifiers

struct TaskBoardItemDragPayload: Codable, Transferable, Sendable {
  let itemID: String
  let status: TaskBoardStatus

  static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: .harnessMonitorTaskBoardItem)
  }

  var sourceLane: TaskBoardInboxLane? {
    TaskBoardInboxLane(status: status)
  }

  func itemProvider() -> NSItemProvider {
    let provider = NSItemProvider()
    guard let encodedPayload = try? JSONEncoder().encode(self) else {
      return provider
    }
    provider.registerDataRepresentation(
      forTypeIdentifier: UTType.harnessMonitorTaskBoardItem.identifier,
      visibility: .all
    ) { completion in
      completion(encodedPayload, nil)
      return nil
    }
    return provider
  }

  static func loadFirst(
    from providers: [NSItemProvider],
    completion: @escaping @MainActor (Self) -> Void
  ) -> Bool {
    guard
      let provider = providers.first(where: {
        $0.hasItemConformingToTypeIdentifier(UTType.harnessMonitorTaskBoardItem.identifier)
      })
    else {
      return false
    }
    provider.loadDataRepresentation(
      forTypeIdentifier: UTType.harnessMonitorTaskBoardItem.identifier
    ) { data, _ in
      guard
        let data,
        let payload = try? JSONDecoder().decode(Self.self, from: data)
      else {
        return
      }
      Task { @MainActor in
        completion(payload)
      }
    }
    return true
  }
}

struct TaskBoardInboxItemDragPayload: Codable, Transferable, Sendable {
  let sessionID: String
  let taskID: String
  let status: TaskStatus
  private let laneRawValue: String

  enum CodingKeys: String, CodingKey {
    case sessionID
    case taskID
    case status
    case laneRawValue
  }

  init(sessionID: String, taskID: String, status: TaskStatus, lane: TaskBoardInboxLane) {
    self.sessionID = sessionID
    self.taskID = taskID
    self.status = status
    laneRawValue = lane.rawValue
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sessionID = try container.decode(String.self, forKey: .sessionID)
    taskID = try container.decode(String.self, forKey: .taskID)
    status = try container.decode(TaskStatus.self, forKey: .status)
    laneRawValue = try container.decode(String.self, forKey: .laneRawValue)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(sessionID, forKey: .sessionID)
    try container.encode(taskID, forKey: .taskID)
    try container.encode(status, forKey: .status)
    try container.encode(laneRawValue, forKey: .laneRawValue)
  }

  static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: .harnessMonitorTaskBoardInboxItem)
  }

  var sourceLane: TaskBoardInboxLane? {
    TaskBoardInboxLane(rawValue: laneRawValue)
  }

  func itemProvider() -> NSItemProvider {
    let provider = NSItemProvider()
    guard let encodedPayload = try? JSONEncoder().encode(self) else {
      return provider
    }
    provider.registerDataRepresentation(
      forTypeIdentifier: UTType.harnessMonitorTaskBoardInboxItem.identifier,
      visibility: .all
    ) { completion in
      completion(encodedPayload, nil)
      return nil
    }
    return provider
  }

  static func loadFirst(
    from providers: [NSItemProvider],
    completion: @escaping @MainActor (Self) -> Void
  ) -> Bool {
    guard
      let provider = providers.first(where: {
        $0.hasItemConformingToTypeIdentifier(UTType.harnessMonitorTaskBoardInboxItem.identifier)
      })
    else {
      return false
    }
    provider.loadDataRepresentation(
      forTypeIdentifier: UTType.harnessMonitorTaskBoardInboxItem.identifier
    ) { data, _ in
      guard
        let data,
        let payload = try? JSONDecoder().decode(Self.self, from: data)
      else {
        return
      }
      Task { @MainActor in
        completion(payload)
      }
    }
    return true
  }
}

extension UTType {
  static let harnessMonitorTaskBoardItem = UTType(
    exportedAs: "io.harnessmonitor.task-board-item",
    conformingTo: .json
  )

  static let harnessMonitorTaskBoardInboxItem = UTType(
    exportedAs: "io.harnessmonitor.task-board-inbox-item",
    conformingTo: .json
  )
}

struct TaskBoardItemRow: View {
  let item: TaskBoardItem
  let onOpenItem: (TaskBoardItem) -> Void
  @Environment(\.fontScale)
  private var fontScale

  private var dragPayload: TaskBoardItemDragPayload {
    TaskBoardItemDragPayload(itemID: item.id, status: item.status)
  }

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }
  private var titleFont: Font {
    HarnessMonitorTextSize.scaledFont(.subheadline.weight(.semibold), by: fontScale)
  }
  private var subtitleFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }

  var body: some View {
    Button {
      onOpenItem(item)
    } label: {
      VStack(alignment: .leading, spacing: metrics.laneSpacing) {
        HStack(alignment: .top, spacing: metrics.laneSpacing) {
          TaskBoardCardLeadingIcon(systemImage: statusSymbol, tint: statusTint)
            .padding(.top, metrics.cardMarkerTopPadding)
          VStack(alignment: .leading, spacing: metrics.rowTextSpacing) {
            Text(item.title)
              .font(titleFont)
              .foregroundStyle(HarnessMonitorTheme.ink)
              .lineLimit(2)
              .multilineTextAlignment(.leading)
            Text(item.projectId ?? item.agentMode.title)
              .font(subtitleFont)
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              .lineLimit(1)
              .truncationMode(.middle)
          }
          Spacer(minLength: 0)
        }
        ViewThatFits(in: .horizontal) {
          HStack(spacing: metrics.laneBodyTopPadding) {
            badgeContent
          }
          VStack(alignment: .leading, spacing: metrics.laneBodyTopPadding) {
            badgeContent
          }
        }
      }
      .frame(
        maxWidth: .infinity,
        minHeight: metrics.cardMinHeight,
        alignment: .topLeading
      )
      .padding(metrics.cardPadding)
    }
    .taskBoardCardChrome()
    .contentShape(.rect)
    .onDrag {
      dragPayload.itemProvider()
    }
    .draggable(dragPayload) {
      TaskBoardItemDragPreviewCard(item: item)
    }
    .accessibilityIdentifier("harness.task-board.api-item.\(item.id)")
  }

  private var statusTint: Color {
    taskBoardStatusColor(for: item.status)
  }

  private var statusSymbol: String {
    TaskBoardInboxLane(status: item.status)?.systemImage ?? "tray"
  }

  @ViewBuilder private var badgeContent: some View {
    TaskBoardCardPill(label: item.status.title, tint: statusTint)
    TaskBoardCardPill(label: item.priority.title, tint: priorityColor(for: item.priority))
    if let policyTraceCount = item.workflow?.policyTraceIds.count, policyTraceCount > 0 {
      TaskBoardCardPill(label: "\(policyTraceCount) policy", tint: HarnessMonitorTheme.secondaryInk)
    }
  }
}

private struct TaskBoardItemDragPreviewCard: View {
  let item: TaskBoardItem
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }

  var body: some View {
    VStack(alignment: .leading, spacing: metrics.laneBodyTopPadding) {
      Text(item.title)
        .scaledFont(.subheadline.weight(.semibold))
        .lineLimit(2)
      Text(item.status.title)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(taskBoardStatusColor(for: item.status))
    }
    .frame(width: metrics.dragPreviewWidth, alignment: .leading)
    .padding(metrics.cardPadding)
    .background(.background.opacity(0.92), in: .rect(cornerRadius: metrics.cardCornerRadius))
  }
}

struct TaskBoardInboxItemRow: View {
  let item: TaskBoardInboxItem
  let onOpenItem: (TaskBoardInboxItem) -> Void
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }
  private var titleFont: Font {
    HarnessMonitorTextSize.scaledFont(.subheadline.weight(.semibold), by: fontScale)
  }
  private var subtitleFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }

  private var dragPayload: TaskBoardInboxItemDragPayload {
    TaskBoardInboxItemDragPayload(
      sessionID: item.session.sessionId,
      taskID: item.task.taskId,
      status: item.task.status,
      lane: item.lane
    )
  }

  var body: some View {
    Button {
      onOpenItem(item)
    } label: {
      VStack(alignment: .leading, spacing: metrics.laneSpacing) {
        HStack(alignment: .top, spacing: metrics.laneSpacing) {
          TaskBoardCardLeadingIcon(systemImage: statusSymbol, tint: statusTint)
            .padding(.top, metrics.cardMarkerTopPadding)
          VStack(alignment: .leading, spacing: metrics.rowTextSpacing) {
            Text(item.task.title)
              .font(titleFont)
              .foregroundStyle(HarnessMonitorTheme.ink)
              .lineLimit(2)
              .multilineTextAlignment(.leading)
            Text(item.subtitle)
              .font(subtitleFont)
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              .lineLimit(1)
              .truncationMode(.middle)
          }
          Spacer(minLength: 0)
        }
        ViewThatFits(in: .horizontal) {
          HStack(spacing: metrics.laneBodyTopPadding) {
            badgeContent
          }
          VStack(alignment: .leading, spacing: metrics.laneBodyTopPadding) {
            badgeContent
          }
        }
      }
      .frame(
        maxWidth: .infinity,
        minHeight: metrics.cardMinHeight,
        alignment: .topLeading
      )
      .padding(metrics.cardPadding)
    }
    .taskBoardCardChrome()
    .contentShape(.rect)
    .onDrag {
      dragPayload.itemProvider()
    }
    .draggable(dragPayload) {
      TaskBoardInboxItemDragPreviewCard(item: item)
    }
    .accessibilityIdentifier("harness.task-board.item.\(item.task.taskId)")
  }

  private var statusTint: Color {
    taskStatusColor(for: item.task.status)
  }

  private var statusSymbol: String {
    item.lane.systemImage
  }

  @ViewBuilder private var badgeContent: some View {
    TaskBoardCardPill(label: item.task.status.title, tint: statusTint)
    TaskBoardCardPill(label: item.task.severity.title, tint: severityColor(for: item.task.severity))
  }
}

private struct TaskBoardInboxItemDragPreviewCard: View {
  let item: TaskBoardInboxItem
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }

  var body: some View {
    VStack(alignment: .leading, spacing: metrics.laneBodyTopPadding) {
      Text(item.task.title)
        .scaledFont(.subheadline.weight(.semibold))
        .lineLimit(2)
      Text(item.task.status.title)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(taskStatusColor(for: item.task.status))
    }
    .frame(width: metrics.dragPreviewWidth, alignment: .leading)
    .padding(metrics.cardPadding)
    .background(.background.opacity(0.92), in: .rect(cornerRadius: metrics.cardCornerRadius))
  }
}

func priorityColor(for priority: TaskBoardPriority) -> Color {
  switch priority {
  case .critical:
    HarnessMonitorTheme.danger
  case .high:
    HarnessMonitorTheme.caution
  case .medium:
    HarnessMonitorTheme.accent
  case .low:
    HarnessMonitorTheme.secondaryInk
  }
}

func taskBoardStatusColor(for status: TaskBoardStatus) -> Color {
  switch status {
  case .blocked:
    HarnessMonitorTheme.danger
  case .planReview, .needsYou, .inReview:
    HarnessMonitorTheme.caution
  case .planning, .inProgress:
    HarnessMonitorTheme.warmAccent
  case .new, .todo:
    HarnessMonitorTheme.accent
  case .done:
    HarnessMonitorTheme.secondaryInk
  case .unknown:
    HarnessMonitorTheme.secondaryInk
  }
}
