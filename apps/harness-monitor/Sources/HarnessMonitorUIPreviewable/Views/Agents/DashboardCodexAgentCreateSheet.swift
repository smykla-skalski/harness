import HarnessMonitorKit
import Observation
import SwiftUI

struct DashboardCodexAgentCreateSheet: View {
  let store: HarnessMonitorStore
  let sessions: [SessionSummary]
  let onCreated: (CodexRunSnapshot, SessionSummary) -> Void
  @Environment(\.dismiss)
  private var dismiss
  @State private var state: DashboardCodexAgentCreateState

  init(
    store: HarnessMonitorStore,
    sessions: [SessionSummary],
    initialCatalogs: [RuntimeModelCatalog] = [],
    onCreated: @escaping (CodexRunSnapshot, SessionSummary) -> Void
  ) {
    self.store = store
    self.sessions = sessions
    self.onCreated = onCreated
    _state = State(
      initialValue: DashboardCodexAgentCreateState(
        catalogs: initialCatalogs,
        defaultSessionID: sessions.first?.sessionId
      )
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      Form {
        workspaceSection
        promptSection
        runtimeSection
        if let issue = state.issue {
          Section {
            Label(issue.withoutTrailingPeriod, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(HarnessMonitorTheme.danger)
            Button("Retry") { loadCatalog(force: true) }
              .disabled(state.isLoadingCatalog || state.isStarting)
          }
        }
      }
      .formStyle(.grouped)
      Divider()
      footer
    }
    .frame(minWidth: 620, idealWidth: 680, minHeight: 620, idealHeight: 680)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardCodexCreateSheet)
    .task { loadCatalog(force: false) }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text("New Codex agent").scaledFont(.title2.weight(.semibold))
      Text("Start a durable managed Codex run in a selected project and worktree")
        .scaledFont(.callout)
        .foregroundStyle(.secondary)
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var workspaceSection: some View {
    Section("Workspace") {
      Picker("Project and worktree", selection: $state.selectedSessionID) {
        ForEach(workspaces) { session in
          Text("\(session.projectName) — \(session.checkoutDisplayName)")
            .tag(session.sessionId)
        }
      }
      .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardCodexWorkspacePicker)
      if let session = selectedSession {
        Text(session.checkoutRoot)
          .scaledFont(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
    }
  }

  private var promptSection: some View {
    Section("First prompt") {
      TextField("Agent name", text: $state.name)
        .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardCodexNameField)
      TextEditor(text: $state.prompt)
        .frame(minHeight: 110, maxHeight: 180)
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary) }
        .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardCodexPromptField)
      Text("The prompt is required and becomes the first durable transcript entry")
        .scaledFont(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var runtimeSection: some View {
    Section("Runtime") {
      Picker("Run mode", selection: $state.mode) {
        ForEach(CodexRunMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      if state.isLoadingCatalog {
        ProgressView("Loading Codex models")
      }
      Picker("Model", selection: $state.selectedModelID) {
        ForEach(codexCatalog?.models ?? []) { model in
          Text(model.displayName).tag(model.id)
        }
        Text("Custom model").tag(SessionWindowCreateFormCatalogs.RuntimeCustomModel.tag)
      }
      if state.selectedModelID == SessionWindowCreateFormCatalogs.RuntimeCustomModel.tag {
        TextField("Provider-specific model ID", text: $state.customModelID)
      }
      if !effortValues.isEmpty {
        Picker("Effort", selection: $state.selectedEffort) {
          ForEach(effortValues, id: \.self) { effort in
            Text(effort.capitalized).tag(effort)
          }
        }
        .pickerStyle(.segmented)
      }
    }
  }

  private var footer: some View {
    HStack {
      Button("Cancel", role: .cancel) { dismiss() }
        .keyboardShortcut(.cancelAction)
      Spacer()
      Button("Start agent") { startAgent() }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(!canStart)
        .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardCodexStartButton)
    }
    .padding(16)
  }

  private var workspaces: [SessionSummary] {
    var seen: Set<DashboardAgentWorkspaceIdentity> = []
    return sessions.filter { session in
      seen.insert(
        DashboardAgentWorkspaceIdentity(
          projectID: session.projectId,
          checkoutID: session.checkoutId
        )
      ).inserted
    }
  }

  private var selectedSession: SessionSummary? {
    workspaces.first { $0.sessionId == state.selectedSessionID }
  }

  private var codexCatalog: RuntimeModelCatalog? {
    state.catalogs.first { $0.runtime == AgentTuiRuntime.codex.rawValue }
  }

  private var effortValues: [String] {
    guard let codexCatalog else { return SessionWindowCreateFormCatalogs.allEffortLevels }
    return SessionWindowCreateFormCatalogs.effortValues(
      catalog: codexCatalog,
      selectedModelID: state.selectedModelID
    )
  }

  private var canStart: Bool {
    selectedSession != nil && !state.isStarting
      && !state.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func loadCatalog(force: Bool) {
    guard state.beginCatalogLoad(force: force) else { return }
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Loading Dashboard Codex models") {
        let catalogs = await store.fetchRuntimeModelCatalogs()
        await state.finishCatalogLoad(catalogs)
      }
    )
  }

  private func startAgent() {
    guard let session = selectedSession, state.beginStart() else { return }
    let selection = SessionWindowCreateFormCatalogs.effectiveModelSelection(
      pickerValue: codexCatalog == nil ? "" : state.selectedModelID,
      customValue: state.customModelID,
      catalogDefault: codexCatalog?.default ?? ""
    )
    let prompt = state.prompt
    let name = state.name
    let mode = state.mode
    let effort = normalizedEffort
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Starting Dashboard Codex agent") {
        let snapshot = await store.startDashboardCodexAgent(
          sessionID: session.sessionId,
          request: CodexRunRequest(
            actor: nil,
            prompt: prompt,
            mode: mode,
            name: name,
            model: selection.id,
            effort: effort,
            allowCustomModel: selection.allowCustomModel
          )
        )
        await state.finishStart(succeeded: snapshot != nil)
        guard let snapshot else { return }
        await MainActor.run {
          onCreated(snapshot, session)
          dismiss()
        }
      }
    )
  }

  private var normalizedEffort: String? {
    let trimmed = state.selectedEffort.trimmingCharacters(in: .whitespacesAndNewlines)
    if effortValues.contains(trimmed) { return trimmed }
    return SessionWindowCreateFormCatalogs.defaultEffortLevel(from: effortValues).nilIfEmpty
  }
}

@MainActor
@Observable
private final class DashboardCodexAgentCreateState {
  var selectedSessionID: String
  var name = ""
  var prompt = ""
  var mode: CodexRunMode = .workspaceWrite
  var selectedModelID = ""
  var customModelID = ""
  var selectedEffort = ""
  private(set) var catalogs: [RuntimeModelCatalog]
  private(set) var isLoadingCatalog = false
  private(set) var isStarting = false
  private(set) var issue: String?
  private var hasLoadedCatalog: Bool

  init(catalogs: [RuntimeModelCatalog], defaultSessionID: String?) {
    self.catalogs = catalogs
    selectedSessionID = defaultSessionID ?? ""
    hasLoadedCatalog = !catalogs.isEmpty
    applyCatalogDefaults()
  }

  func beginCatalogLoad(force: Bool) -> Bool {
    guard !isLoadingCatalog, force || !hasLoadedCatalog else { return false }
    isLoadingCatalog = true
    issue = nil
    return true
  }

  func finishCatalogLoad(_ catalogs: [RuntimeModelCatalog]) {
    self.catalogs = catalogs
    isLoadingCatalog = false
    hasLoadedCatalog = true
    issue = catalogs.isEmpty ? "The daemon returned no runtime model catalog" : nil
    applyCatalogDefaults()
  }

  func beginStart() -> Bool {
    guard !isStarting else { return false }
    isStarting = true
    issue = nil
    return true
  }

  func finishStart(succeeded: Bool) {
    isStarting = false
    if !succeeded { issue = "The daemon did not start the Codex agent" }
  }

  private func applyCatalogDefaults() {
    guard let catalog = catalogs.first(where: { $0.runtime == AgentTuiRuntime.codex.rawValue })
    else {
      selectedModelID = SessionWindowCreateFormCatalogs.RuntimeCustomModel.tag
      selectedEffort = SessionWindowCreateFormCatalogs.allEffortLevels.first ?? ""
      return
    }
    selectedModelID = catalog.default
    let efforts = SessionWindowCreateFormCatalogs.effortValues(
      catalog: catalog,
      selectedModelID: catalog.default
    )
    selectedEffort = SessionWindowCreateFormCatalogs.defaultEffortLevel(from: efforts)
  }
}

extension String {
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
