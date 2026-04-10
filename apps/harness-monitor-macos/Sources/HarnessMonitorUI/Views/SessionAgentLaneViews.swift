import AppKit
import HarnessMonitorKit
import SwiftUI

struct SessionAgentListSection: View {
  let store: HarnessMonitorStore
  let sessionID: String
  let agents: [AgentRegistration]
  let tasks: [WorkItem]
  let isSessionReadOnly: Bool
  let inspectAgent: (String) -> Void

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
              inspectAgent: inspectAgent
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
  @State private var isDropTargeted = false

  private var runtimeSymbol: ProviderBrandSymbol? {
    switch agent.runtime.lowercased() {
    case "claude", "anthropic":
      .claude
    case "codex", "openai":
      .openAI
    case "gemini":
      .gemini
    case "copilot":
      .copilot
    case "mistral":
      .mistral
    default:
      nil
    }
  }

  private var metadataLine: String {
    guard runtimeSymbol == nil else {
      return agent.agentId
    }
    return "\(agent.runtime.uppercased()) • \(agent.agentId)"
  }

  private var roleTint: Color {
    switch agent.role {
    case .leader:
      Color(red: 0.35, green: 0.61, blue: 0.96)
    case .worker:
      Color(red: 0.16, green: 0.73, blue: 0.63)
    case .observer:
      Color(red: 0.52, green: 0.56, blue: 0.94)
    case .reviewer:
      Color(red: 0.95, green: 0.50, blue: 0.33)
    case .improver:
      Color(red: 0.78, green: 0.41, blue: 0.84)
    }
  }

  private var roleForeground: Color {
    guard let rgbColor = NSColor(roleTint).usingColorSpace(.deviceRGB) else {
      return HarnessMonitorTheme.onContrast
    }

    let luminance = relativeLuminance(
      red: rgbColor.redComponent,
      green: rgbColor.greenComponent,
      blue: rgbColor.blueComponent
    )
    let contrastWithWhite = (1.0 + 0.05) / (luminance + 0.05)
    let contrastWithDark = (luminance + 0.05) / (0.03 + 0.05)

    return contrastWithDark >= contrastWithWhite
      ? Color.black.opacity(0.82)
      : HarnessMonitorTheme.onContrast
  }

  private var isWorkerDropTarget: Bool {
    !isSessionReadOnly && agent.status == .active && agent.role == .worker
  }

  private var queueSummary: String {
    guard !queuedTasks.isEmpty else {
      return agent.currentTaskId == nil ? "Ready" : "Working"
    }
    let suffix = queuedTasks.count == 1 ? "task" : "tasks"
    return "\(queuedTasks.count) queued \(suffix)"
  }

  var body: some View {
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
      .clipped()
    }
    .harnessInteractiveCardButtonStyle()
    .dropDestination(for: TaskDragPayload.self, action: handleTaskDrop, isTargeted: { targeted in
      isDropTargeted = targeted && isWorkerDropTarget
    })
    .overlay {
      if isDropTargeted {
        RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
          .stroke(HarnessMonitorTheme.accent, lineWidth: 2)
          .allowsHitTesting(false)
      }
    }
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
    .transition(
      .asymmetric(
        insertion: .scale(scale: 0.95).combined(with: .opacity),
        removal: .opacity
      ))
  }

  private func handleTaskDrop(_ payloads: [TaskDragPayload], _: CGPoint) -> Bool {
    guard isWorkerDropTarget else {
      return false
    }
    guard let payload = payloads.first, payload.sessionID == sessionID else {
      return false
    }
    Task {
      await store.dropTask(
        taskID: payload.taskID,
        target: .agent(agentId: agent.agentId)
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

#Preview("Agent summary") {
  SessionAgentSummaryCard(
    store: HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded),
    sessionID: PreviewFixtures.summary.sessionId,
    agent: PreviewFixtures.agents[1],
    queuedTasks: [],
    isSessionReadOnly: false,
    inspectAgent: { _ in }
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
