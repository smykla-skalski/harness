import AppKit
import HarnessMonitorKit
import SwiftUI

struct SessionAgentListSection: View {
  let store: HarnessMonitorStore
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
            SessionAgentSummaryCard(store: store, agent: agent, inspectAgent: inspectAgent)
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
    agent: PreviewFixtures.agents[1],
    inspectAgent: { _ in }
  )
  .padding()
  .frame(width: 320)
}
