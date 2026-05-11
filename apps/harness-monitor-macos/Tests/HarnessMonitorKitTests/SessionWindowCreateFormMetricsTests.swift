import Foundation
import HarnessMonitorKit
import Testing

@testable import HarnessMonitorUIPreviewable

// swiftlint:disable file_length
// swiftlint:disable type_body_length
@Suite("Session window create form metrics")
struct SessionWindowCreateFormMetricsTests {
  @Test("Metrics scale form padding and preserve large submit hit target")
  func metricsScaleFormPaddingAndPreserveLargeHitTarget() {
    let regular = SessionWindowCreateFormMetrics(fontScale: 1.0)
    let large = SessionWindowCreateFormMetrics(fontScale: 1.8)

    #expect(large.formPadding > regular.formPadding)
    #expect(large.promptMinHeight > regular.promptMinHeight)
    #expect(large.submitButtonMinHeight == 44)
  }

  @Test("Metrics clamp extreme font scales")
  func metricsClampExtremeFontScales() {
    #expect(
      SessionWindowCreateFormMetrics(fontScale: 0.1)
        == SessionWindowCreateFormMetrics(fontScale: 0.85)
    )
    #expect(
      SessionWindowCreateFormMetrics(fontScale: 9.0)
        == SessionWindowCreateFormMetrics(fontScale: 1.8)
    )
  }

  @Test("Validation requires a non-empty name")
  func validationRequiresNonEmptyName() {
    let blank = SessionCreateDraft(kind: .agent, title: "   ", sessionID: "session-1")
    let named = SessionCreateDraft(kind: .agent, title: "Review worker", sessionID: "session-1")

    #expect(SessionWindowCreateFormValidation.message(for: blank) == "Agent name is required.")
    #expect(SessionWindowCreateFormValidation.message(for: named) == nil)
    #expect(SessionWindowCreateFormValidation.result(for: blank)?.field == .name)
  }

  @Test("Draft launch selection preserves legacy runtime and provider storage keys")
  func draftLaunchSelectionPreservesLegacyRuntimeAndProviderStorageKeys() {
    let legacyRuntime = SessionCreateDraft(
      kind: .agent,
      runtime: AgentTuiRuntime.gemini.rawValue,
      sessionID: "session-1"
    )
    let projectAccess = SessionCreateDraft(
      kind: .agent,
      runtime: AgentLaunchSelection.acp("copilot").storageKey,
      sessionID: "session-1"
    )

    #expect(legacyRuntime.launchSelection == .tui(.gemini))
    #expect(projectAccess.launchSelection == .acp("copilot"))
  }

  @Test("Task draft preserves severity in the in-window form")
  func taskDraftPreservesSeverityInWindowForm() {
    var draft = SessionCreateDraft(
      kind: .task,
      taskSeverity: .critical,
      sessionID: "session-1"
    )

    #expect(draft.taskSeverity == .critical)
    draft.taskSeverityRawValue = "legacy"
    #expect(draft.taskSeverity == .medium)
    draft.taskSeverity = .high
    #expect(draft.taskSeverityRawValue == "high")
  }

  @Test("Agent draft preserves session role, persona, and argv overrides")
  func agentDraftPreservesRolePersonaAndArgvOverrides() {
    var draft = SessionCreateDraft(kind: .agent, sessionID: "session-1")

    #expect(draft.role == .worker)
    #expect(draft.fallbackRole == .worker)

    draft.role = .leader
    draft.fallbackRole = .observer
    draft.personaID = "reviewer"
    draft.argvOverride = "codex\n--model\ngpt-5\n\n"

    #expect(draft.roleRawValue == SessionRole.leader.rawValue)
    #expect(draft.fallbackRoleRawValue == SessionRole.observer.rawValue)
    #expect(draft.personaID == "reviewer")
    #expect(draft.normalizedArgvOverride == ["codex", "--model", "gpt-5"])
  }

  @MainActor
  @Test("Fresh agent draft restores saved launch preset fields")
  func freshAgentDraftRestoresSavedLaunchPresetFields() throws {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    let snapshot = LaunchPresetSnapshot(
      mode: .terminal,
      providerStorageKey: AgentLaunchSelection.tui(.gemini).storageKey,
      role: SessionRole.leader.rawValue,
      fallbackRole: SessionRole.observer.rawValue,
      personaID: "reviewer",
      modelByRuntime: ["gemini": "gemini-2.5-pro"],
      customModelByRuntime: ["claude": "claude-sonnet-custom"],
      effortByRuntime: ["gemini": "high"],
      codexMode: CodexRunMode.workspaceWrite.rawValue,
      customCodexModel: "gpt-5.5-custom",
      codexEffort: "medium"
    )
    guard let encodedSnapshot = LaunchPresetDefaults.encode(snapshot) else {
      Issue.record("Expected launch preset snapshot to encode")
      return
    }
    defaults.set(encodedSnapshot, forKey: LaunchPresetDefaults.storageKey)

    let draft = SessionWindowStateCache.freshCreateDraft(
      kind: .agent,
      sessionID: "session-1",
      userDefaults: defaults
    )

    #expect(draft.runtime == AgentLaunchSelection.tui(.gemini).storageKey)
    #expect(draft.role == .leader)
    #expect(draft.fallbackRole == .observer)
    #expect(draft.personaID == "reviewer")
    #expect(draft.modelByRuntime["gemini"] == "gemini-2.5-pro")
    #expect(draft.customModelByRuntime["claude"] == "claude-sonnet-custom")
    #expect(draft.effortByRuntime["gemini"] == "high")
    #expect(draft.codexMode == .workspaceWrite)
    #expect(draft.codexModel == "gpt-5.5-custom")
    #expect(draft.codexAllowCustomModel)
    #expect(draft.codexEffort == "medium")
  }

  @MainActor
  @Test("Fresh agent normalization prefers ACP for the stored provider")
  func freshAgentNormalizationPrefersAcpForStoredProvider() {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    HarnessMonitorAgentLaunchDefaults.persist(.tui(.copilot), userDefaults: defaults)
    let draft = SessionWindowStateCache.freshCreateDraft(
      kind: .agent,
      sessionID: "session-1",
      userDefaults: defaults
    )
    let options = AgentCapabilityCatalog.options(
      acpAgents: [descriptor(id: "copilot", displayName: "GitHub Copilot")],
      runtimeProbeResults: readyProbeResults(for: ["copilot"])
    )

    #expect(
      SessionWindowCreateFormCatalogs.normalizedLaunchSelection(
        draft: draft,
        options: options,
        userDefaults: defaults
      ) == .acp("copilot")
    )
  }

  @MainActor
  @Test("Manual selection keeps the chosen transport during normalization")
  func manualSelectionKeepsChosenTransportDuringNormalization() {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    HarnessMonitorAgentLaunchDefaults.persist(.acp("copilot"), userDefaults: defaults)
    let draft = SessionCreateDraft(
      kind: .agent,
      runtime: AgentLaunchSelection.tui(.copilot).storageKey,
      sessionID: "session-1"
    )
    let options = AgentCapabilityCatalog.options(
      acpAgents: [descriptor(id: "copilot", displayName: "GitHub Copilot")],
      runtimeProbeResults: readyProbeResults(for: ["copilot"])
    )

    #expect(
      SessionWindowCreateFormCatalogs.normalizedLaunchSelection(
        draft: draft,
        options: options,
        didPickLaunchSelectionManually: true,
        userDefaults: defaults
      ) == .tui(.copilot)
    )
  }

  @Test("Validation rejects unavailable selected capability")
  func validationRejectsUnavailableSelectedCapability() {
    let draft = SessionCreateDraft(
      kind: .agent,
      title: "Review worker",
      runtime: AgentLaunchSelection.acp("copilot").storageKey,
      sessionID: "session-1"
    )
    let option = AgentCapabilityOption(
      id: "copilot",
      title: "Copilot",
      transportChoices: [
        AgentCapabilityTransportChoice(
          id: .acp("copilot"),
          title: "ACP",
          capabilities: ["workspace.read"]
        )
      ],
      doctorProbe: nil,
      probe: nil,
      installHint: nil,
      sandboxed: true,
      acpHostBridgeReady: false
    )

    #expect(
      SessionWindowCreateFormValidation.message(for: draft, capabilityOptions: [option])
        == "Turn on bridge access to use ACP here"
    )
    #expect(
      SessionWindowCreateFormValidation.result(for: draft, capabilityOptions: [option])?.field
        == .capability
    )
  }

  @MainActor
  @Test("Cancelling a create draft clears it and returns to its section")
  func cancellingCreateDraftClearsItAndReturnsToSection() {
    let state = SessionWindowStateCache(sessionID: "session-1")

    state.selectCreate(.decision)
    var draft = SessionCreateDraft(kind: .decision, sessionID: "session-1")
    draft.title = "Review prompt"
    state.updateCreateDraft(draft)
    state.cancelCreateDraft(.decision)

    #expect(!state.sectionState.hasDraft(.decision))
    #expect(state.selection == .route(.decisions))
    #expect(state.navigationHistory.backStack.allSatisfy { $0.createDraft == nil })
    #expect(state.navigationHistory.forwardStack.allSatisfy { $0.createDraft == nil })
  }

  @Test("Create form keeps focus and cancel affordances in source")
  func createFormKeepsFocusAndCancelAffordancesInSource() throws {
    let source = try sourceFile(named: "SessionWindowCreateForm.swift")
    let submissionSource = try sourceFile(named: "SessionWindowCreateForm+Submission.swift")
    let runtimePaneSource = try sourceFile(named: "SessionWindowCreateAgentRuntimePane.swift")

    #expect(source.contains("@FocusState"))
    #expect(source.contains("Button(\"Cancel\", role: .cancel)"))
    #expect(submissionSource.contains("SessionWindowCreateFormValidation.result"))
    #expect(source.contains("validationMessage(for: .name)"))
    #expect(source.contains("Validation error:"))
    #expect(submissionSource.contains("focusedField = .name"))
    #expect(source.contains("embeddedAgentRuntimeSections"))
    #expect(source.contains("embedsRuntimeConfiguration"))
    #expect(source.contains("SessionWindowCreateTransportChoicesGroup("))
    #expect(source.contains("SessionWindowCreateRuntimeModelPickerRow("))
    #expect(source.contains("SessionWindowCreateRuntimeCustomModelRow("))
    #expect(source.contains("SessionWindowCreateRuntimeEffortRow("))
    #expect(!source.contains("SessionWindowCreateRuntimeModelControls("))
    #expect(source.contains(".equatable()"))
    #expect(!source.contains("ViewThatFits(in: .horizontal)"))
    #expect(!source.contains("SessionWindowCreateFormAgentLaunchToggle("))
    #expect(!source.contains("SessionWindowCreateFormCapabilityPicker("))
    #expect(!source.contains("SessionWindowCreateAgentRuntimeContent("))
    #expect(!source.contains("DisclosureGroup(\""))
    #expect(!source.contains("SessionWindowCreateFieldBlock("))
    #expect(
      source.contains(".contentMargins(.horizontal, metrics.formPadding, for: .scrollContent)"))
    #expect(source.contains(".contentMargins(.vertical, metrics.formPadding, for: .scrollContent)"))
    #expect(!source.contains(".padding(metrics.formPadding)"))
    #expect(source.contains("Picker(\"Provider\", selection: selectedProviderID)"))
    #expect(!source.contains("Picker(\"Create\", selection: useCodex)"))
    #expect(source.contains("Text(\"Runtime\")"))
    #expect(source.contains("Text(\"Session\")"))
    #expect(source.contains("Text(\"Advanced overrides\")"))
    #expect(!source.contains("Optional project directory override"))
    #expect(runtimePaneSource.contains("SessionWindowCreateProviderListRow"))
    #expect(runtimePaneSource.contains("HarnessMonitorColumnScrollView("))
    #expect(
      runtimePaneSource.contains("SessionWindowCreateSidebarSectionHeader(title: \"Provider\")"))
    #expect(runtimePaneSource.contains("\"New agent\""))
    #expect(!runtimePaneSource.contains("sessionWindowCreateModePicker"))
    #expect(!runtimePaneSource.contains("List(selection: selectedProviderID)"))
    #expect(!runtimePaneSource.contains("LazyVGrid("))
    #expect(runtimePaneSource.contains("loadAgentCatalogStateIfNeeded("))
    #expect(!runtimePaneSource.contains("capabilitySummary"))
    #expect(!runtimePaneSource.contains("providerDescription"))
    #expect(!runtimePaneSource.contains("minHeight: 36"))
    #expect(!runtimePaneSource.contains("Divider()"))
    #expect(
      !runtimePaneSource.contains(
        ".padding(.horizontal, embeddedInForm ? 0 : HarnessMonitorTheme.spacingXS)"))
    #expect(runtimePaneSource.contains(".truncationMode(.tail)"))
    #expect(!runtimePaneSource.contains(".padding(.horizontal, HarnessMonitorTheme.spacingMD)"))
    #expect(runtimePaneSource.contains(".padding(.vertical, HarnessMonitorTheme.spacingXS)"))
    #expect(!runtimePaneSource.contains(".buttonStyle(.plain)"))
    #expect(source.contains("Picker(\"Severity\", selection: taskSeverity)"))
    #expect(submissionSource.contains("sessionID: draft.sessionID"))
    #expect(submissionSource.contains("startAcpAgent("))
    #expect(!submissionSource.contains("createCodexRun(named:"))
    #expect(!submissionSource.contains("draft.useCodex"))
    #expect(!source.contains("requestCreateTaskSheet()"))
    #expect(!source.contains(".keyboardShortcut(\"n\", modifiers: [.command])"))
    #expect(source.contains(".keyboardShortcut(.defaultAction)"))
  }

  @Test("Runtime configuration support is split between catalog and pane sources")
  func runtimeConfigurationSupportIsSplitBetweenCatalogAndPaneSources() throws {
    let catalogSource = try sourceFile(named: "SessionWindowCreateFormCatalogs.swift")
    let formSource = try sourceFile(named: "SessionWindowCreateForm.swift")
    let runtimePaneSource = try sourceFile(named: "SessionWindowCreateAgentRuntimePane.swift")
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
    #expect(runtimePaneSource.contains("SessionWindowCreateProviderListRow"))
    #expect(runtimePaneSource.contains("providerSubtitle(for: option)"))
    #expect(runtimePaneSource.contains("HarnessMonitorColumnScrollView("))
    #expect(runtimePaneSource.contains("Text(title.uppercased())"))
    #expect(runtimePaneSource.contains("VStack(spacing: HarnessMonitorTheme.spacingXS)"))
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
      ) == "No persona selected."
    )
  }

  private func sourceFile(named relativePath: String) throws -> String {
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

  private func agentSourceFile(named relativePath: String) throws -> String {
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
        "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views/Agents"
      )
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
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
// swiftlint:enable type_body_length
