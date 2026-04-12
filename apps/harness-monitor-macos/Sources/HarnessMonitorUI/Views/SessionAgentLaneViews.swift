import HarnessMonitorKit
import SwiftUI

struct SessionAgentListSection: View {
  let store: HarnessMonitorStore
  let sessionID: String
  let agents: [AgentRegistration]
  let tasks: [WorkItem]
  let isSessionReadOnly: Bool
  let inspectAgent: (String) -> Void
  let tuiStatusByAgent: [String: AgentTuiStatus]

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      Text("Agents")
        .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      if agents.isEmpty {
        ContentUnavailableView {
          Label("No agents registered", systemImage: "person.2")
        } description: {
          Text("Agents appear here when they join the session.")
        }
      } else {
        LazyVStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
          ForEach(agents) { agent in
            SessionAgentSummaryCard(
              store: store,
              sessionID: sessionID,
              agent: agent,
              queuedTasks: tasks.queued(for: agent.agentId),
              isSessionReadOnly: isSessionReadOnly,
              inspectAgent: inspectAgent,
              tuiStatus: tuiStatusByAgent[agent.agentId]
            )
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }
}

struct SessionAgentSummaryCard: View {
  let store: HarnessMonitorStore
  let sessionID: String
  let agent: AgentRegistration
  let queuedTasks: [WorkItem]
  let isSessionReadOnly: Bool
  let inspectAgent: (String) -> Void
  let tuiStatus: AgentTuiStatus?
  @State private var isDropTargeted = false

  private var runtimeSymbol: ProviderBrandSymbol? {
    ProviderBrandSymbol(runtimeString: agent.runtime)
  }

  private var metadataLine: String {
    guard runtimeSymbol == nil else {
      return agent.agentId
    }
    return "\(agent.runtime.uppercased()) • \(agent.agentId)"
  }

  private var roleTint: Color {
    let components = roleTintComponents
    return Color(red: components.red, green: components.green, blue: components.blue)
  }

  private var roleTintComponents: RoleTintRGB {
    switch agent.role {
    case .leader:
      RoleTintRGB(red: 0.35, green: 0.61, blue: 0.96)
    case .worker:
      RoleTintRGB(red: 0.16, green: 0.73, blue: 0.63)
    case .observer:
      RoleTintRGB(red: 0.52, green: 0.56, blue: 0.94)
    case .reviewer:
      RoleTintRGB(red: 0.95, green: 0.50, blue: 0.33)
    case .improver:
      RoleTintRGB(red: 0.78, green: 0.41, blue: 0.84)
    }
  }

  private var roleForeground: Color {
    let rgbColor = roleTintComponents
    let luminance = relativeLuminance(
      red: rgbColor.red,
      green: rgbColor.green,
      blue: rgbColor.blue
    )
    let contrastWithWhite = (1.0 + 0.05) / (luminance + 0.05)
    let contrastWithDark = (luminance + 0.05) / (0.03 + 0.05)

    return contrastWithDark >= contrastWithWhite
      ? Color.black.opacity(0.82)
      : HarnessMonitorTheme.onContrast
  }

  private var tuiMarkerColor: Color {
    guard let tuiStatus else { return .clear }
    switch tuiStatus {
    case .running:
      return HarnessMonitorTheme.success
    case .stopped:
      return HarnessMonitorTheme.caution
    case .exited:
      return HarnessMonitorTheme.secondaryInk
    case .failed:
      return HarnessMonitorTheme.danger
    }
  }

  private var taskDropAction: AgentTaskDropAction {
    AgentTaskDropAction(
      agent: agent,
      queuedTaskCount: queuedTasks.count,
      isSessionReadOnly: isSessionReadOnly
    )
  }

  private var queueSummary: String {
    guard !queuedTasks.isEmpty else {
      return agent.currentTaskId == nil ? "Ready" : "Working"
    }
    let suffix = queuedTasks.count == 1 ? "task" : "tasks"
    return "\(queuedTasks.count) queued \(suffix)"
  }

  var body: some View {
    ZStack {
      Button {
        inspectAgent(agent.agentId)
      } label: {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
          HStack(alignment: .top) {
            Text(agent.name)
              .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
              .lineLimit(2)
            Spacer()
            Text(agent.role.title)
              .scaledFont(.caption.bold())
              .harnessPillPadding()
              .background(roleTint, in: Capsule())
              .foregroundStyle(roleForeground)
          }
          Text(metadataLine)
            .scaledFont(.caption.monospaced())
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .lineLimit(1)
          Spacer(minLength: 0)
          if let currentTaskId = agent.currentTaskId {
            Text("Current \(currentTaskId)")
              .scaledFont(.caption.monospaced())
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              .lineLimit(1)
          }
          HStack(spacing: HarnessMonitorTheme.itemSpacing) {
            badge(agent.runtimeCapabilities.supportsContextInjection ? "Context" : "Watch")
            badge("\(agent.runtimeCapabilities.typicalSignalLatencySeconds)s")
            badge(queueSummary)
          }
        }
        .frame(
          maxWidth: .infinity,
          minHeight: SessionCockpitLayout.laneCardHeight,
          alignment: .topLeading
        )
        .padding(HarnessMonitorTheme.cardPadding)
        .overlay(alignment: .bottomTrailing) {
          if let runtimeSymbol {
            ProviderBrandSymbolView(
              symbol: runtimeSymbol,
              colorMode: .automaticContrast,
              size: 110
            )
            .opacity(0.12)
            .offset(x: 18, y: 22)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
          }
        }
        .overlay(alignment: .bottomTrailing) {
          if tuiStatus != nil {
            Image(systemName: "terminal")
              .font(.system(size: 20))
              .foregroundStyle(tuiMarkerColor)
              .padding(HarnessMonitorTheme.spacingSM)
              .accessibilityLabel("Agent TUI \(tuiStatus?.title ?? "")")
              .accessibilityIdentifier(
                HarnessMonitorAccessibility.sessionAgentTuiMarker(agent.agentId)
              )
              .harnessUITestValue(tuiStatus?.rawValue ?? "")
              .allowsHitTesting(false)
          }
        }
        .clipped()
      }
      .harnessInteractiveCardButtonStyle()
      .contextMenu {
        Button {
          inspectAgent(agent.agentId)
        } label: {
          Label("Inspect", systemImage: "info.circle")
        }
        Button {
          store.presentSendSignalSheet(agentID: agent.agentId)
        } label: {
          Label("Send Signal", systemImage: "paperplane")
        }
        .disabled(store.isSessionReadOnly)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.sessionAgentSignalTrigger(agent.agentId)
        )
        Divider()
        Button {
          HarnessMonitorClipboard.copy(agent.agentId)
        } label: {
          Label("Copy Agent ID", systemImage: "doc.on.doc")
        }
      }
      .accessibilityIdentifier(HarnessMonitorAccessibility.sessionAgentCard(agent.agentId))
      .accessibilityFrameMarker(
        "\(HarnessMonitorAccessibility.sessionAgentCard(agent.agentId)).frame"
      )
      if showPulseBorder {
        DropTargetPulseBorder()
          .transition(.opacity)
      }
      if let feedback = taskDropFeedback {
        ZStack {
          AgentTaskDropFeedbackOverlay(feedback: feedback)
          Color.clear
            .accessibilityTestProbe(
              HarnessMonitorAccessibility.sessionAgentTaskDropFeedback(agent.agentId),
              label: feedback.accessibilityLabel
            )
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
      }
    }
    .contentShape(.rect)
    .dropDestination(for: TaskDragPayload.self, action: handleTaskDrop) { targeted in
      isDropTargeted = targeted
    }
    .animation(.easeInOut(duration: 0.12), value: isDropTargeted)
    .animation(.easeInOut(duration: 0.2), value: showPulseBorder)
  }

  private var showPulseBorder: Bool {
    store.contentUI.session.isTaskDragActive
      && taskDropAction.feedback.isActionable
      && !isDropTargeted
  }

  private var taskDropFeedback: AgentTaskDropFeedback? {
    guard isDropTargeted else {
      return nil
    }
    return taskDropAction.feedback
  }

  private func handleTaskDrop(_ payloads: [TaskDragPayload], _: CGPoint) -> Bool {
    guard let payload = payloads.first else {
      store.reportDropRejection("Cannot assign task: no task payload in drop.")
      return false
    }
    guard payload.sessionID == sessionID else {
      store.reportDropRejection(
        "Cannot assign task: drag source does not belong to this session."
      )
      return false
    }
    guard let targetAgentID = taskDropAction.targetAgentID else {
      store.reportDropRejection(taskDropAction.feedback.accessibilityLabel)
      return false
    }
    Task {
      await store.dropTask(
        taskID: payload.taskID,
        target: .agent(agentId: targetAgentID),
        queuePolicy: payload.queuePolicy
      )
    }
    return true
  }

  private func badge(_ value: String) -> some View {
    Text(value)
      .scaledFont(.caption.weight(.semibold))
      .lineLimit(1)
      .harnessPillPadding()
      .harnessContentPill()
  }

  private func relativeLuminance(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGFloat {
    (0.2126 * linearized(red)) + (0.7152 * linearized(green)) + (0.0722 * linearized(blue))
  }

  private func linearized(_ component: CGFloat) -> CGFloat {
    if component <= 0.04045 {
      return component / 12.92
    }
    return pow((component + 0.055) / 1.055, 2.4)
  }
}

#Preview("Agent summary - TUI running") {
  SessionAgentSummaryCard(
    store: HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded),
    sessionID: PreviewFixtures.summary.sessionId,
    agent: PreviewFixtures.agents[1],
    queuedTasks: [],
    isSessionReadOnly: false,
    inspectAgent: { _ in },
    tuiStatus: .running
  )
  .padding()
  .frame(width: 320)
}

#Preview("Agent summary - no TUI") {
  SessionAgentSummaryCard(
    store: HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded),
    sessionID: PreviewFixtures.summary.sessionId,
    agent: PreviewFixtures.agents[1],
    queuedTasks: [],
    isSessionReadOnly: false,
    inspectAgent: { _ in },
    tuiStatus: nil
  )
  .padding()
  .frame(width: 320)
}

private extension [WorkItem] {
  func queued(for agentID: String) -> [WorkItem] {
    filter { task in
      task.assignedTo == agentID && task.isQueuedForWorker
    }
    .sorted { lhs, rhs in
      (lhs.queuedAt ?? lhs.updatedAt, lhs.taskId) < (rhs.queuedAt ?? rhs.updatedAt, rhs.taskId)
    }
  }
}

private struct RoleTintRGB {
  let red: CGFloat
  let green: CGFloat
  let blue: CGFloat
}

private struct DropTargetPulseBorder: View {
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  var body: some View {
    RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
      .stroke(HarnessMonitorTheme.success, lineWidth: 1.5)
      .modifier(PulseOpacityModifier(reduceMotion: reduceMotion))
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

private struct PulseOpacityModifier: ViewModifier {
  let reduceMotion: Bool

  func body(content: Content) -> some View {
    if reduceMotion {
      content.opacity(0.6)
    } else {
      content.phaseAnimator([0.25, 0.7]) { border, opacity in
        border.opacity(opacity)
      } animation: { _ in
        .easeInOut(duration: 1.1)
      }
    }
  }
}
