import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Session window create form catalogs")
@MainActor
struct SessionWindowCreateFormCatalogsSelectionTests {
  @Test("New agent form keeps Claude on Terminal while Claude ACP is deferred")
  func newAgentFormKeepsClaudeOnTerminalWhileClaudeAcpIsDeferred() throws {
    let options = SessionWindowCreateFormCatalogs.capabilityOptions(
      acpAgents: [descriptor(id: "claude", displayName: "Claude Code")],
      runtimeProbeResults: readyProbeResults(for: ["claude"])
    )
    let claude = try #require(options.first { $0.id == AgentTuiRuntime.claude.rawValue })

    #expect(claude.transportChoices.map(\.id) == [.tui(.claude)])
    #expect(SessionWindowCreateProviderListRow.availableModes(for: claude) == [.tui])
    #expect(SessionWindowCreateProviderListRow.modeSummary(for: claude) == "Mode TUI")
    #expect(
      SessionWindowCreateFormCatalogs.normalizedLaunchSelection(
        draft: SessionCreateDraft(
          kind: .agent,
          runtime: AgentLaunchSelection.acp("claude").storageKey,
          sessionID: "session-1"
        ),
        options: options,
        didPickLaunchSelectionManually: true
      ) == .tui(.claude)
    )
    #expect(
      SessionWindowCreateProviderListRow.providerSubtitle(for: claude)
        == "This provider opens in Terminal only"
    )
  }

  @Test("New agent rows show ACP and TUI badges for ACP-ready providers")
  func newAgentRowsShowAcpAndTuiBadgesForAcpReadyProviders() {
    let option = AgentCapabilityOption(
      id: "codex",
      title: "Codex",
      transportChoices: [
        AgentCapabilityTransportChoice(
          id: .acp("codex"),
          title: "ACP",
          capabilities: ["fs.read", "fs.write", "terminal.spawn"]
        ),
        AgentCapabilityTransportChoice(
          id: .tui(.codex),
          title: "Terminal screen",
          capabilities: ["streaming", "multi-turn"]
        ),
      ],
      doctorProbe: AcpDoctorProbe(command: "harness-codex-acp", args: ["--probe"]),
      probe: AcpRuntimeProbe(
        agentId: "codex",
        displayName: "Codex",
        binaryPresent: true,
        authState: .ready
      ),
      installHint: nil,
      bundledWithHarness: true,
      sandboxed: false,
      acpHostBridgeReady: true
    )

    #expect(SessionWindowCreateProviderListRow.availableModes(for: option) == [.acp, .tui])
    #expect(SessionWindowCreateProviderListRow.modeSummary(for: option) == "Modes ACP and TUI")
    #expect(
      SessionWindowCreateProviderListRow.accessibilityLabel(for: option)
        == "Codex, Modes ACP and TUI, Terminal and ACP are available."
    )
  }

  @Test("Codex app server mode badge uses distinct label")
  func codexAppServerModeBadgeUsesDistinctLabel() {
    let option = AgentCapabilityOption(
      id: "codex",
      title: "Codex",
      transportChoices: [
        AgentCapabilityTransportChoice(
          id: .codex,
          title: "Codex",
          capabilities: ["streaming", "multi-turn", "approvals", "app-server"]
        ),
        AgentCapabilityTransportChoice(
          id: .acp("codex"),
          title: "ACP",
          capabilities: ["fs.read", "fs.write", "terminal.spawn"]
        ),
        AgentCapabilityTransportChoice(
          id: .tui(.codex),
          title: "Terminal screen",
          capabilities: ["streaming", "multi-turn"]
        ),
      ],
      doctorProbe: AcpDoctorProbe(command: "harness-codex-acp", args: ["--probe"]),
      probe: AcpRuntimeProbe(
        agentId: "codex",
        displayName: "Codex",
        binaryPresent: true,
        authState: .ready
      ),
      installHint: nil,
      bundledWithHarness: true,
      sandboxed: false,
      acpHostBridgeReady: true
    )

    #expect(
      SessionWindowCreateProviderListRow.availableModes(for: option)
        == [.codex, .acp, .tui]
    )
    #expect(
      SessionWindowCreateProviderListRow.modeSummary(for: option)
        == "Modes App Server, ACP, and TUI"
    )
    #expect(
      SessionWindowCreateProviderListRow.accessibilityLabel(for: option)
        == "Codex, Modes App Server, ACP, and TUI, Codex app server is available."
    )
  }

  @Test("Provider mode badges use static footer-style font and flat chrome")
  func providerModeBadgesUseStaticFooterStyleFontAndFlatChrome() throws {
    let source = try sessionSourceFile(named: "SessionWindowCreateAgentRuntimePane+Support.swift")

    #expect(
      source.contains(
        "Text(mode.rawValue)\n      .font(.system(.caption2, design: .rounded, weight: .semibold))"
      )
    )
    #expect(source.contains("private let cornerRadius: CGFloat = 8"))
    #expect(source.contains("case codex = \"App Server\""))
    #expect(
      source.contains(
        "case .codex:\n      HarnessMonitorTheme.warmAccent"
      )
    )
    #expect(source.contains("private let horizontalPadding: CGFloat = 6"))
    #expect(source.contains("private let verticalPadding: CGFloat = 2"))
    #expect(source.contains(".padding(.horizontal, horizontalPadding)"))
    #expect(source.contains(".padding(.vertical, verticalPadding)"))
    #expect(source.contains("return \"Codex App Server\""))
    #expect(source.contains(".accessibilityLabel(\"\\(providerTitle), \\(shortTitle)\")"))
    #expect(!source.contains("return \"Codex\""))
    #expect(
      source.contains(
        "RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)\n          .fill(mode.fill)"
      )
    )
    #expect(
      source.contains(
        "var foreground: Color {\n    HarnessMonitorProminentButtonContrast.foreground(for: fill)\n  }"
      )
    )
    #expect(!source.contains("Text(mode.rawValue)\n      .scaledFont(.caption.weight(.semibold))"))
    #expect(!source.contains("Capsule()"))
    #expect(!source.contains(".strokeBorder("))
    #expect(!source.contains(".harnessContentPill(tint: mode.tint)"))
  }

  @Test("ACP selections resolve the Codex runtime model catalog")
  func acpSelectionsResolveCodexRuntimeModelCatalog() {
    let catalogState = SessionWindowAgentCreateCatalogState(
      descriptors: PreviewHarnessClient.previewAcpAgentDescriptors,
      runtimeModelCatalogs: PreviewHarnessClient.previewRuntimeModelCatalogs,
      capabilityOptions: [],
      personas: [],
      isLoading: false,
      hasLoaded: true
    )

    #expect(
      SessionWindowCreateFormCatalogs.selectedModelCatalog(
        selection: .acp("codex"),
        catalogState: catalogState
      )?.runtime == "codex"
    )
  }

  @Test("Native Codex selections resolve the Codex runtime model catalog")
  func nativeCodexSelectionsResolveCodexRuntimeModelCatalog() {
    let catalogState = SessionWindowAgentCreateCatalogState(
      descriptors: PreviewHarnessClient.previewAcpAgentDescriptors,
      runtimeModelCatalogs: PreviewHarnessClient.previewRuntimeModelCatalogs,
      capabilityOptions: [],
      personas: [],
      isLoading: false,
      hasLoaded: true
    )

    #expect(
      SessionWindowCreateFormCatalogs.selectedModelCatalog(
        selection: .codex,
        catalogState: catalogState
      )?.runtime == "codex"
    )
  }

  @Test("Cached capability options refresh live bridge availability")
  func cachedCapabilityOptionsRefreshLiveBridgeAvailability() throws {
    let cachedOption = AgentCapabilityOption(
      id: "codex",
      title: "Codex",
      transportChoices: [
        AgentCapabilityTransportChoice(
          id: .codex,
          title: "Codex",
          capabilities: ["streaming", "multi-turn", "approvals", "app-server"]
        ),
        AgentCapabilityTransportChoice(
          id: .acp("codex"),
          title: "ACP",
          capabilities: ["fs.read", "fs.write", "terminal.spawn"]
        ),
        AgentCapabilityTransportChoice(
          id: .tui(.codex),
          title: "Terminal screen",
          capabilities: ["streaming", "multi-turn"]
        ),
      ],
      doctorProbe: AcpDoctorProbe(command: "harness-codex-acp", args: ["--probe"]),
      probe: AcpRuntimeProbe(
        agentId: "codex",
        displayName: "Codex",
        binaryPresent: true,
        authState: .ready
      ),
      installHint: nil,
      bundledWithHarness: true,
      sandboxed: true,
      acpHostBridgeReady: false,
      codexHostBridgeReady: false
    )

    let refreshed = try #require(
      SessionWindowCreateFormCatalogs.refreshedCapabilityOptions(
        [cachedOption],
        sandboxed: true,
        acpHostBridgeReady: true,
        codexHostBridgeReady: true
      ).first
    )

    let codexChoice = try #require(refreshed.codexChoice)
    let acpChoice = try #require(refreshed.acpChoice)
    #expect(refreshed.isEnabled(codexChoice))
    #expect(refreshed.isEnabled(acpChoice))
    #expect(refreshed.availabilityState == .projectAccessAvailable)
  }

  @Test("Bridge access relies on the top banner instead of inline transport warnings")
  func bridgeAccessUsesTopBannerInsteadOfInlineTransportWarnings() {
    let option = AgentCapabilityOption(
      id: "codex",
      title: "Codex",
      transportChoices: [
        AgentCapabilityTransportChoice(
          id: .codex,
          title: "Codex",
          capabilities: ["streaming", "multi-turn", "approvals", "app-server"]
        ),
        AgentCapabilityTransportChoice(
          id: .acp("codex"),
          title: "ACP",
          capabilities: ["fs.read", "fs.write", "terminal.spawn"]
        ),
        AgentCapabilityTransportChoice(
          id: .tui(.codex),
          title: "Terminal screen",
          capabilities: ["streaming", "multi-turn"]
        ),
      ],
      doctorProbe: AcpDoctorProbe(command: "harness-codex-acp", args: ["--probe"]),
      probe: AcpRuntimeProbe(
        agentId: "codex",
        displayName: "Codex",
        binaryPresent: true,
        authState: .ready
      ),
      installHint: nil,
      bundledWithHarness: true,
      sandboxed: true,
      acpHostBridgeReady: false,
      codexHostBridgeReady: false
    )

    #expect(option.availabilityState == .bridgeAccessRequired)
    #expect(!SessionWindowCreateFormCatalogs.shouldSurfaceInlineUnavailableReason(for: option))
    #expect(!SessionWindowCreateFormCatalogs.shouldShowTransportDiagnosticsDisclosure(for: option))
  }

  @Test("Catalog helpers clamp stale picker selections to rendered tags")
  func catalogHelpersClampStalePickerSelectionsToRenderedTags() {
    let catalog = RuntimeModelCatalog(
      runtime: "codex",
      models: [
        RuntimeModel(
          id: "gpt-5-mini",
          displayName: "GPT-5 mini",
          tier: .fast
        ),
        RuntimeModel(
          id: "gpt-5",
          displayName: "GPT-5",
          tier: .balanced
        ),
      ],
      default: "gpt-5",
      cheapestFastest: "gpt-5-mini"
    )

    #expect(
      SessionWindowCreateFormCatalogs.normalizedRuntimeModelPickerValue(
        storedValue: "gpt-4-stale",
        catalog: catalog
      ) == "gpt-5"
    )
    #expect(
      SessionWindowCreateFormCatalogs.normalizedRuntimeModelPickerValue(
        storedValue: SessionWindowCreateFormCatalogs.RuntimeCustomModel.tag,
        catalog: catalog
      ) == SessionWindowCreateFormCatalogs.RuntimeCustomModel.tag
    )
  }

  @Test("OpenRouter picker helper clamps stale selections to live model tags")
  func openRouterPickerHelperClampsStaleSelectionsToLiveModelTags() {
    let defaultModel = OpenRouterModelEntry(
      id: HarnessMonitorStore.defaultOpenRouterModel,
      name: "Claude 3.7 Sonnet"
    )
    let fallbackModel = OpenRouterModelEntry(
      id: "openai/gpt-5.5",
      name: "GPT-5.5"
    )

    #expect(
      SessionWindowCreateFormCatalogs.normalizedOpenRouterModelPickerValue(
        storedValue: "anthropic/claude-sonnet-4-6",
        availableModels: [defaultModel, fallbackModel]
      ) == HarnessMonitorStore.defaultOpenRouterModel
    )
    #expect(
      SessionWindowCreateFormCatalogs.normalizedOpenRouterModelPickerValue(
        storedValue: "anthropic/claude-sonnet-4-6",
        availableModels: [fallbackModel]
      ) == fallbackModel.id
    )
  }

  private func descriptor(id: String, displayName: String) -> AcpAgentDescriptor {
    AcpAgentDescriptor(
      id: id,
      displayName: displayName,
      capabilities: ["fs.read", "terminal.spawn"],
      launchCommand: id,
      launchArgs: ["--acp"],
      envPassthrough: [],
      installHint: nil,
      doctorProbe: AcpDoctorProbe(command: id, args: ["--version"])
    )
  }

  private func readyProbeResults(for ids: [String]) -> AcpRuntimeProbeResponse {
    AcpRuntimeProbeResponse(
      probes: ids.map { id in
        AcpRuntimeProbe(
          agentId: id,
          displayName: id,
          binaryPresent: true,
          authState: .ready
        )
      },
      checkedAt: "2026-05-11T12:00:00Z"
    )
  }

  private func sessionSourceFile(named relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent(
        "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views/Sessions"
      )
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
