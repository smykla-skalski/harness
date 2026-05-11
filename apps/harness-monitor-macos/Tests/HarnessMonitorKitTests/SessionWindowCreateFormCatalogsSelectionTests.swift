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
}
