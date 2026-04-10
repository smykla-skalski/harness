import Foundation

public enum HarnessMonitorNotificationPreset: String, CaseIterable, Identifiable, Sendable {
  case basic
  case sessionFinished
  case actionRequest
  case richImage

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .basic: "Basic"
    case .sessionFinished: "Session Finished"
    case .actionRequest: "Action Request"
    case .richImage: "Rich Image"
    }
  }

  public var draft: HarnessMonitorNotificationDraft {
    switch self {
    case .basic:
      HarnessMonitorNotificationDraft()
    case .sessionFinished:
      HarnessMonitorNotificationDraft(
        title: "Harness session finished",
        subtitle: "worker-codex",
        body: "The selected session completed with a clean verdict.",
        threadIdentifier: "session-finished",
        targetContentIdentifier: "session-summary",
        filterCriteria: "session",
        summaryArgument: "worker-codex",
        summaryArgumentCount: 1,
        category: .statusActions,
        soundMode: .systemDefault,
        attachmentMode: .none,
        interruptionMode: .active,
        relevanceScore: 0.72
      )
    case .actionRequest:
      HarnessMonitorNotificationDraft(
        title: "Review needed",
        subtitle: "leader-claude",
        body: "Approve the next run step or reply with updated context.",
        threadIdentifier: "manual-actions",
        targetContentIdentifier: "agent-action",
        filterCriteria: "action-required",
        summaryArgument: "leader-claude",
        summaryArgumentCount: 2,
        category: .textInput,
        soundMode: .systemDefault,
        attachmentMode: .none,
        interruptionMode: .timeSensitive,
        relevanceScore: 0.9
      )
    case .richImage:
      HarnessMonitorNotificationDraft(
        title: "Timeline snapshot ready",
        subtitle: "Rich notification",
        body: "A generated image attachment is included for visual testing.",
        threadIdentifier: "timeline-snapshots",
        targetContentIdentifier: "timeline",
        filterCriteria: "image",
        category: .fullControls,
        soundMode: .systemDefault,
        attachmentMode: .sampleImage,
        interruptionMode: .active,
        relevanceScore: 0.8
      )
    }
  }
}
