import HarnessMonitorKit
import SwiftUI

struct SessionAgentListSection: View {
  let agents: [AgentRegistration]
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
            SessionAgentSummaryCard(agent: agent, inspectAgent: inspectAgent)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }
}

struct SessionAgentSummaryCard: View {
  let agent: AgentRegistration
  let inspectAgent: (String) -> Void
  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration

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

  var body: some View {
    Button { inspectAgent(agent.agentId) } label: {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
        HStack(alignment: .top) {
          Text(agent.name)
            .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
            .lineLimit(2)
          Spacer()
          Text(agent.role.title)
            .scaledFont(.caption.bold())
            .harnessPillPadding()
            .background(HarnessMonitorTheme.accent, in: Capsule())
            .foregroundStyle(HarnessMonitorTheme.onContrast)
        }
        HStack(spacing: 8) {
          if let runtimeSymbol {
            ProviderBrandSymbolView(
              symbol: runtimeSymbol,
              colorMode: .automaticContrast,
              size: 14
            )
            .accessibilityHidden(true)
          } else {
            Text(agent.runtime.uppercased())
              .scaledFont(.caption2.weight(.semibold))
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              .lineLimit(1)
          }

          Text(agent.agentId)
            .scaledFont(.caption.monospaced())
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
        HStack(spacing: HarnessMonitorTheme.itemSpacing) {
          badge(agent.runtimeCapabilities.supportsContextInjection ? "Context" : "Watch")
          badge("\(agent.runtimeCapabilities.typicalSignalLatencySeconds)s")
          badge(formatTimestamp(agent.lastActivityAt, configuration: dateTimeConfiguration))
        }
      }
      .frame(
        maxWidth: .infinity,
        minHeight: SessionCockpitLayout.laneCardHeight,
        alignment: .topLeading
      )
      .padding(HarnessMonitorTheme.cardPadding)
    }
    .harnessInteractiveCardButtonStyle()
    .contextMenu {
      Button { inspectAgent(agent.agentId) } label: {
        Label("Inspect", systemImage: "info.circle")
      }
      Divider()
      Button {
        HarnessMonitorClipboard.copy(agent.agentId)
      } label: {
        Label("Copy Agent ID", systemImage: "doc.on.doc")
      }
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.sessionAgentCard(agent.agentId))
    .accessibilityFrameMarker("\(HarnessMonitorAccessibility.sessionAgentCard(agent.agentId)).frame")
    .transition(
      .asymmetric(
        insertion: .scale(scale: 0.95).combined(with: .opacity),
        removal: .opacity
      ))
  }

  private func badge(_ value: String) -> some View {
    Text(value)
      .scaledFont(.caption.weight(.semibold))
      .lineLimit(1)
      .harnessPillPadding()
      .harnessContentPill()
  }
}

#Preview("Agent summary") {
  SessionAgentSummaryCard(agent: PreviewFixtures.agents[1], inspectAgent: { _ in })
    .padding()
    .frame(width: 320)
}
