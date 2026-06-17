import HarnessMonitorKit
import SwiftUI

struct SessionAgentSummaryCard: View {
  let store: HarnessMonitorStore
  let sessionID: String
  let sessionRegistrations: [AgentRegistration]
  let agent: AgentRegistration
  let queuedTasks: [WorkItem]
  let isSessionReadOnly: Bool
  let openAgent: (String) -> Void
  let tuiStatus: AgentTuiStatus?
  @State private var isDropTargeted = false
  @State private var pendingDroppedTaskID: String?

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
    case .starting:
      return HarnessMonitorTheme.caution
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

  private var personaTint: Color {
    Color(red: 0.82, green: 0.68, blue: 0.21)
  }

  private var taskDropAction: AgentTaskDropAction {
    AgentTaskDropAction(
      agent: agent,
      queuedTaskCount: queuedTasks.count,
      isSessionReadOnly: isSessionReadOnly
    )
  }

  private var lifecyclePresentation: HarnessMonitorStore.AgentLifecyclePresentation {
    store.agentLifecyclePresentation(
      for: agent,
      sessionID: sessionID,
      sessionRegistrations: sessionRegistrations,
      tuiStatus: tuiStatus
    )
  }

  private var activityPresentation: HarnessMonitorStore.AgentActivityPresentation {
    store.agentActivityPresentation(
      for: agent,
      sessionID: sessionID,
      sessionRegistrations: sessionRegistrations,
      queuedTasks: queuedTasks,
      tuiStatus: tuiStatus
    )
  }

  private var shouldShowActivityBadge: Bool {
    activityPresentation.label != lifecyclePresentation.label
  }

  var body: some View {
    ZStack {
      Button {
        openAgent(agent.agentId)
      } label: {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
          HStack(alignment: .top) {
            Text(verbatim: agent.name)
              .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
              .lineLimit(2)
            Spacer()
            Text(verbatim: agent.role.title)
              .scaledFont(.caption.bold())
              .harnessPillPadding()
              .background(roleTint, in: Capsule())
              .foregroundStyle(roleForeground)
          }
          if let persona = agent.persona {
            HStack(spacing: HarnessMonitorTheme.spacingXS) {
              PersonaSymbolView(symbol: persona.symbol, size: 14)
              Text(verbatim: persona.name)
                .scaledFont(.caption.weight(.semibold))
            }
            .foregroundStyle(personaTint)
            .accessibilityLabel("Persona: \(persona.name)")
            .accessibilityIdentifier(HarnessMonitorAccessibility.agentRowPersonaChip(agent.agentId))
          }
          Text(verbatim: metadataLine)
            .scaledFont(.caption.monospaced())
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .lineLimit(1)
          Spacer(minLength: 0)
          if lifecyclePresentation.visualStatus == .active,
            let currentTaskId = agent.currentTaskId
          {
            Text(verbatim: "Current \(currentTaskId)")
              .scaledFont(.caption.monospaced())
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              .lineLimit(1)
          }
          HStack(spacing: HarnessMonitorTheme.itemSpacing) {
            badge(
              lifecyclePresentation.label,
              accessibilityValue: lifecyclePresentation.accessibilityValue
            )
            if shouldShowActivityBadge {
              badge(
                activityPresentation.label,
                accessibilityValue: activityPresentation.accessibilityValue
              )
            }
            badge(agent.runtimeCapabilities.supportsContextInjection ? "Context" : "Watch")
            badge("\(agent.runtimeCapabilities.typicalSignalLatencySeconds)s")
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
              .accessibilityLabel("Agents \(tuiStatus?.title ?? "")")
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
          openAgent(agent.agentId)
        } label: {
          Label("Open in Agents", systemImage: "rectangle.on.rectangle.angled")
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
      .harnessTrackMCPElement(
        HarnessMonitorAccessibility.sessionAgentCard(agent.agentId),
        kind: .row,
        label: agent.name,
        pressAction: { openAgent(agent.agentId) }
      )
      .accessibilityFrameMarker(
        "\(HarnessMonitorAccessibility.sessionAgentCard(agent.agentId)).frame"
      )
      if showPulseBorder {
        DropTargetPulseBorder()
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
      }
    }
    .contentShape(.rect)
    .dropDestination(for: TaskDragPayload.self, action: handleTaskDrop) { targeted in
      isDropTargeted = targeted
    }
  }

  private var showPulseBorder: Bool {
    store.contentUI.session.isTaskDragActive
      && taskDropAction.feedback.isActionable
      && !isDropTargeted
      && pendingDroppedTaskID == nil
  }

  private var taskDropFeedback: AgentTaskDropFeedback? {
    if pendingDroppedTaskID != nil {
      return taskDropAction.pendingFeedback
    }
    guard isDropTargeted else {
      return nil
    }
    return taskDropAction.feedback
  }

  private func handleTaskDrop(_ payloads: [TaskDragPayload], _: CGPoint) -> Bool {
    guard let payload = payloads.first else {
      store.reportDropRejection("Cannot assign task: no task payload in drop")
      return false
    }
    guard payload.sessionID == sessionID else {
      store.reportDropRejection(
        "Cannot assign task: drag source does not belong to this session"
      )
      return false
    }
    guard let targetAgentID = taskDropAction.targetAgentID else {
      store.reportDropRejection(taskDropAction.feedback.accessibilityLabel)
      return false
    }
    let droppedTaskID = payload.taskID
    pendingDroppedTaskID = droppedTaskID
    Task {
      await store.dropTask(
        taskID: droppedTaskID,
        target: .agent(agentId: targetAgentID),
        queuePolicy: payload.queuePolicy
      )
      await MainActor.run {
        if pendingDroppedTaskID == droppedTaskID {
          pendingDroppedTaskID = nil
        }
      }
    }
    return true
  }

  private func badge(
    _ value: String,
    accessibilityValue: String? = nil
  ) -> some View {
    Text(verbatim: value)
      .scaledFont(.caption.weight(.semibold))
      .lineLimit(1)
      .harnessPillPadding()
      .harnessContentPill()
      .accessibilityLabel(accessibilityValue ?? value)
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
