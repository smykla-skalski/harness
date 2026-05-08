import Foundation
import HarnessMonitorKit
import Testing

@testable import HarnessMonitorUIPreviewable

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
          title: "Project access",
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
        == "Turn on bridge access to use project access here"
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

    #expect(source.contains("@FocusState"))
    #expect(source.contains("Button(\"Cancel\", role: .cancel)"))
    #expect(submissionSource.contains("SessionWindowCreateFormValidation.result"))
    #expect(source.contains("validationMessage(for: .name)"))
    #expect(source.contains("validationMessage(for: .capability)"))
    #expect(source.contains("Validation error:"))
    #expect(submissionSource.contains("focusedField = .name"))
    #expect(source.contains("SessionWindowCreateFormCapabilityPicker"))
    #expect(source.contains("Picker(\"Severity\", selection: taskSeverity)"))
    #expect(submissionSource.contains("sessionID: draft.sessionID"))
    #expect(submissionSource.contains("startAcpAgent("))
    #expect(!source.contains("requestCreateTaskSheet()"))
    #expect(!source.contains(".keyboardShortcut(\"n\", modifiers: [.command])"))
    #expect(source.contains(".keyboardShortcut(.defaultAction)"))
  }

  @Test("Create form capability support is split into catalog and picker sources")
  func createFormCapabilitySupportIsSplitIntoCatalogAndPickerSources() throws {
    let catalogSource = try sourceFile(named: "SessionWindowCreateFormCatalogs.swift")
    let pickerSource = try sourceFile(named: "SessionWindowCreateFormCapabilityPicker.swift")
    let submissionSource = try sourceFile(named: "SessionWindowCreateForm+Submission.swift")
    let sharedCatalogSource = try agentSourceFile(named: "AgentCapabilityCatalog.swift")

    #expect(catalogSource.contains("loadAgentOptions"))
    #expect(catalogSource.contains("fallbackAgentOptions"))
    #expect(pickerSource.contains("AgentCapabilityRow"))
    #expect(submissionSource.contains("loadAgentCapabilitiesIfNeeded"))
    #expect(sharedCatalogSource.contains("enum AgentCapabilityCatalog"))
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
}
