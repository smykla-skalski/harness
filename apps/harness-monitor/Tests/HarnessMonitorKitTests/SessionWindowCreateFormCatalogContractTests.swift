import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension SessionWindowCreateFormMetricsTests {
  @Test("Runtime configuration support is split between catalog and pane sources")
  func runtimeConfigurationSupportIsSplitBetweenCatalogAndPaneSources() throws {
    let catalogSource = try sourceFile(named: "SessionWindowCreateFormCatalogs.swift")
    let formSource = try sourceFile(named: "SessionWindowCreateForm.swift")
    let runtimePaneSource = try sourceFile(named: "SessionWindowCreateAgentRuntimePane.swift")
    let runtimePaneSupportSource = try sourceFile(
      named: "SessionWindowCreateAgentRuntimePane+Support.swift")
    let submissionSource = try sourceFile(named: "SessionWindowCreateForm+Submission.swift")
    let sharedCatalogSource = try agentSourceFile(named: "AgentCapabilityCatalog.swift")

    #expect(catalogSource.contains("loadAgentCatalogStateIfNeeded"))
    #expect(catalogSource.contains("fallbackAgentOptions"))
    #expect(catalogSource.contains("effectiveModelSelection"))
    #expect(catalogSource.contains("fetchPersonas()"))
    #expect(catalogSource.contains("resolvedInitialLaunchSelection"))
    #expect(catalogSource.contains("selectedPersonaStateText"))
    #expect(formSource.contains("embeddedAgentRuntimeSections"))
    #expect(formSource.contains("terminalRuntimeConfigurationSection"))
    #expect(formSource.contains("terminalSessionSection"))
    #expect(formSource.contains("terminalAdvancedOverridesSection"))
    #expect(formSource.contains("selectedProviderID"))
    #expect(!formSource.contains("DisclosureGroup(\""))
    #expect(!formSource.contains("SessionWindowCreateFieldBlock("))
    #expect(!formSource.contains("Picker(\"Create\", selection: useCodex)"))
    #expect(runtimePaneSource.contains("SessionWindowCreateProviderButtonList("))
    #expect(runtimePaneSupportSource.contains("SessionWindowCreateProviderListRow"))
    #expect(runtimePaneSupportSource.contains("providerSubtitle(for: option)"))
    #expect(runtimePaneSource.contains("HarnessMonitorColumnScrollView("))
    #expect(runtimePaneSource.contains("Text(title.uppercased())"))
    #expect(runtimePaneSupportSource.contains("VStack(spacing: HarnessMonitorTheme.spacingXS)"))
    #expect(!runtimePaneSource.contains("List(selection: selectedProviderID)"))
    #expect(!runtimePaneSource.contains("SessionWindowCreateProviderGridCard"))
    #expect(!runtimePaneSource.contains("SessionWindowCreateFieldBlock(title: \"Model\")"))
    #expect(!runtimePaneSource.contains("selectedCodexModelMenuTitle"))
    #expect(submissionSource.contains("writeTerminalLaunchPreset("))
    #expect(submissionSource.contains("role: selectedRole"))
    #expect(submissionSource.contains("fallbackRole: fallbackRole"))
    #expect(!submissionSource.contains("projectDir: context.projectDir"))
    #expect(submissionSource.contains("persona: context.personaID"))
    #expect(submissionSource.contains("model: modelSelection.id"))
    #expect(submissionSource.contains("effort: effort.isEmpty ? nil : effort"))
    #expect(submissionSource.contains("allowCustomModel: modelSelection.allowCustomModel"))
    #expect(submissionSource.contains("argv: draft.normalizedArgvOverride"))
    #expect(submissionSource.contains("state.resetCreateDraft(.agent)"))
    #expect(!submissionSource.contains("createCodexRun(named:"))
    #expect(!submissionSource.contains("loadAgentCapabilitiesIfNeeded"))
    #expect(sharedCatalogSource.contains("enum AgentCapabilityCatalog"))
  }

  @Test("Catalog helpers resolve default and custom runtime models")
  func catalogHelpersResolveDefaultAndCustomRuntimeModels() {
    #expect(
      SessionWindowCreateFormCatalogs.effectiveModelSelection(
        pickerValue: "",
        customValue: "",
        catalogDefault: "gpt-5"
      ).id == "gpt-5"
    )
    #expect(
      SessionWindowCreateFormCatalogs.effectiveModelSelection(
        pickerValue: SessionWindowCreateFormCatalogs.RuntimeCustomModel.tag,
        customValue: "claude-opus",
        catalogDefault: "gpt-5"
      ).id == "claude-opus"
    )
    #expect(
      SessionWindowCreateFormCatalogs.effectiveModelSelection(
        pickerValue: SessionWindowCreateFormCatalogs.RuntimeCustomModel.tag,
        customValue: "claude-opus",
        catalogDefault: "gpt-5"
      ).allowCustomModel
    )
    #expect(
      SessionWindowCreateFormCatalogs.defaultEffortLevel(from: ["low", "medium", "high"])
        == "medium"
    )
  }

  @Test("Catalog helper resolves ACP selections to runtime catalogs")
  func catalogHelperResolvesAcpSelectionsToRuntimeCatalogs() {
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
        selection: .acp("gemini"),
        catalogState: catalogState
      )?.runtime == "gemini"
    )
    #expect(
      SessionWindowCreateFormCatalogs.selectedModelCatalog(
        selection: .acp("claude"),
        catalogState: catalogState
      )?.runtime == "claude"
    )
  }

  @Test("Catalog helper resolves selected persona state text")
  func catalogHelperResolvesSelectedPersonaStateText() {
    let personas = PreviewHarnessClient.previewPersonas

    #expect(
      SessionWindowCreateFormCatalogs.selectedPersonaStateText(
        personaID: "reviewer",
        personas: personas
      ) == "Using Reviewer."
    )
    #expect(
      SessionWindowCreateFormCatalogs.selectedPersonaStateText(
        personaID: "",
        personas: personas
      ) == "No persona selected"
    )
  }

  func sourceFile(named relativePath: String) throws -> String {
    try previewableSourceFile(at: "Views/Sessions/\(relativePath)")
  }

  func previewableSourceFile(at relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }

  func agentSourceFile(named relativePath: String) throws -> String {
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
        "apps/harness-monitor/Sources/HarnessMonitorUIPreviewable/Views/Agents"
      )
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }

  func descriptor(id: String, displayName: String) -> AcpAgentDescriptor {
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

  func readyProbeResults(for ids: [String]) -> AcpRuntimeProbeResponse {
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
