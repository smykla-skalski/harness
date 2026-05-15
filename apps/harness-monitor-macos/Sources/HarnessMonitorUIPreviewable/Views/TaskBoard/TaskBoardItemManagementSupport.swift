import Foundation
import HarnessMonitorKit
import SwiftUI

protocol TitledTaskBoardValue {
  var title: String { get }
}

extension TaskBoardStatus: TitledTaskBoardValue {}
extension TaskBoardPriority: TitledTaskBoardValue {}
extension TaskBoardAgentMode: TitledTaskBoardValue {}

extension TaskBoardExternalRefProvider {
  static let taskBoardCases: [TaskBoardExternalRefProvider] = [.gitHub, .todoist]

  var title: String {
    switch self {
    case .gitHub:
      "GitHub"
    case .todoist:
      "Todoist"
    }
  }
}

struct TaskBoardManagementFact: Identifiable {
  let id: String
  let label: String
  let value: String

  init(_ label: String, value: String) {
    id = label
    self.label = label
    self.value = value
  }
}

struct TaskBoardExternalDestination: Identifiable {
  let label: String
  let url: URL

  var id: URL { url }
}

struct TaskBoardManagementFacts: View {
  let facts: [TaskBoardManagementFact]

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: HarnessMonitorTheme.spacingMD) {
      ForEach(facts) { fact in
        GridRow {
          Text(fact.label)
            .scaledFont(.caption.weight(.semibold))
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          Text(fact.value)
            .scaledFont(.caption)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }
      }
    }
  }
}

struct TaskBoardExternalLinks: View {
  let destinations: [TaskBoardExternalDestination]
  let metrics: TaskBoardOverviewMetrics

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: HarnessMonitorTheme.spacingSM) { links }
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) { links }
    }
  }

  @ViewBuilder private var links: some View {
    ForEach(destinations) { destination in
      Link(destination: destination.url) {
        Label(destination.label, systemImage: "arrow.up.right.square")
          .scaledFont(.caption.weight(.semibold))
      }
      .frame(minHeight: metrics.controlMinHeight)
      .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.accent)
      .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      .help("Open \(destination.label)")
    }
  }
}

extension TaskBoardWorkflowStatus {
  var title: String {
    switch self {
    case .idle:
      "Idle"
    case .running:
      "Running"
    case .paused:
      "Paused"
    case .completed:
      "Completed"
    case .failed:
      "Failed"
    case .cancelled:
      "Cancelled"
    }
  }
}
