import HarnessMonitorKit
import SwiftUI

enum AgentTaskDropAction {
  case start(agentID: String, feedback: AgentTaskDropFeedback)
  case queue(agentID: String, feedback: AgentTaskDropFeedback)
  case unavailable(feedback: AgentTaskDropFeedback)

  var feedback: AgentTaskDropFeedback {
    switch self {
    case .start(_, let feedback), .queue(_, let feedback), .unavailable(let feedback):
      feedback
    }
  }

  var targetAgentID: String? {
    switch self {
    case .start(let agentID, _), .queue(let agentID, _):
      agentID
    case .unavailable:
      nil
    }
  }

  init(
    agent: AgentRegistration,
    queuedTaskCount: Int,
    isSessionReadOnly: Bool
  ) {
    let feedback = AgentTaskDropFeedback(
      agent: agent,
      queuedTaskCount: queuedTaskCount,
      isSessionReadOnly: isSessionReadOnly
    )
    guard feedback.isActionable else {
      self = .unavailable(feedback: feedback)
      return
    }
    if agent.currentTaskId == nil {
      self = .start(agentID: agent.agentId, feedback: feedback)
    } else {
      self = .queue(agentID: agent.agentId, feedback: feedback)
    }
  }
}

struct AgentTaskDropFeedback {
  let title: String
  let detail: String
  let systemImage: String
  let tint: Color
  let isActionable: Bool

  var accessibilityLabel: String {
    "\(title). \(detail)"
  }

  init(
    agent: AgentRegistration,
    queuedTaskCount: Int,
    isSessionReadOnly: Bool
  ) {
    if isSessionReadOnly {
      self.init(
        title: "Read-only session",
        detail: "Task drops are disabled.",
        systemImage: "lock",
        tint: HarnessMonitorTheme.danger,
        isActionable: false
      )
      return
    }

    guard agent.role == .worker else {
      self.init(
        title: "\(agent.role.title) cannot take tasks",
        detail: "Only active workers accept tasks.",
        systemImage: "nosign",
        tint: HarnessMonitorTheme.danger,
        isActionable: false
      )
      return
    }

    guard agent.status == .active else {
      self.init(
        title: "\(agent.status.title) agent",
        detail: "Only active workers accept tasks.",
        systemImage: "pause.circle",
        tint: HarnessMonitorTheme.danger,
        isActionable: false
      )
      return
    }

    guard agent.currentTaskId != nil else {
      self.init(
        title: "Start on this worker",
        detail: "Drop to run it now.",
        systemImage: "play.fill",
        tint: HarnessMonitorTheme.success,
        isActionable: true
      )
      return
    }

    let detail: String
    if queuedTaskCount == 0 {
      detail = "Drop behind the current task."
    } else {
      let taskWord = queuedTaskCount == 1 ? "task" : "tasks"
      detail = "\(queuedTaskCount) \(taskWord) queued."
    }
    self.init(
      title: "Queue for this worker",
      detail: detail,
      systemImage: "text.line.last.and.arrowtriangle.forward",
      tint: HarnessMonitorTheme.caution,
      isActionable: true
    )
  }

  private init(
    title: String,
    detail: String,
    systemImage: String,
    tint: Color,
    isActionable: Bool
  ) {
    self.title = title
    self.detail = detail
    self.systemImage = systemImage
    self.tint = tint
    self.isActionable = isActionable
  }
}

struct AgentTaskDropFeedbackOverlay: View {
  let feedback: AgentTaskDropFeedback

  private var strokeStyle: StrokeStyle {
    if feedback.isActionable {
      return StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
    }
    return StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [6, 4])
  }

  var body: some View {
    Color.clear
      .harnessDragFeedbackSurface(
        cornerRadius: HarnessMonitorTheme.cornerRadiusMD,
        tint: feedback.tint
      )
      .overlay {
        Circle()
          .fill(feedback.tint.opacity(0.32))
          .frame(width: 160, height: 160)
          .blur(radius: 28)
      }
      .overlay {
        ViewThatFits(in: .vertical) {
          compactFeedbackContent(showsDetail: true)
          compactFeedbackContent(showsDetail: false)
        }
        .padding(.horizontal, HarnessMonitorTheme.spacingMD)
        .padding(.vertical, HarnessMonitorTheme.spacingSM)
      }
      .clipShape(
        RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
          .strokeBorder(feedback.tint, style: strokeStyle)
      }
      .allowsHitTesting(false)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(feedback.title)
      .accessibilityValue(feedback.detail)
  }

  @ViewBuilder
  private func compactFeedbackContent(showsDetail: Bool) -> some View {
    VStack(spacing: HarnessMonitorTheme.spacingXS) {
      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        Image(systemName: feedback.systemImage)
          .imageScale(.small)
        Text(feedback.title)
          .scaledFont(.caption.weight(.bold))
          .lineLimit(1)
          .truncationMode(.tail)
          .minimumScaleFactor(0.8)
      }
      if showsDetail {
        Text(feedback.detail)
          .scaledFont(.caption2.weight(.semibold))
          .lineLimit(1)
          .truncationMode(.tail)
          .minimumScaleFactor(0.8)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .multilineTextAlignment(.center)
    .foregroundStyle(feedback.tint)
  }
}
