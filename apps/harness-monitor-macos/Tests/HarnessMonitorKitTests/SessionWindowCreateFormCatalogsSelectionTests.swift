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
        == "This provider opens in Terminal only."
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

  @Test("Provider mode badges use static footer-style font and flat chrome")
  func providerModeBadgesUseStaticFooterStyleFontAndFlatChrome() throws {
    let source = try sessionSourceFile(named: "SessionWindowCreateAgentRuntimePane.swift")

    #expect(
      source.contains(
        "Text(mode.rawValue)\n      .font(.system(.caption2, design: .rounded, weight: .semibold))"
      )
    )
    #expect(source.contains("Capsule()\n          .fill(mode.tint.opacity(fillOpacity))"))
    #expect(!source.contains("Text(mode.rawValue)\n      .scaledFont(.caption.weight(.semibold))"))
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
