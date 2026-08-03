import HarnessMonitorKit
import Observation
import SwiftUI

struct DashboardTerminalAgentCreateSheet: View {
  let store: HarnessMonitorStore
  let workspaces: [SessionSummary]
  let onCreated: (AgentTuiSnapshot, SessionSummary) -> Void
  let onStartFailed: () -> Void
  @Environment(\.dismiss)
  private var dismiss
  @State private var state: DashboardTerminalAgentCreateState

  init(
    store: HarnessMonitorStore,
    sessions: [SessionSummary],
    onCreated: @escaping (AgentTuiSnapshot, SessionSummary) -> Void,
    onStartFailed: @escaping () -> Void = {}
  ) {
    self.store = store
    let workspaces = Self.uniqueWorkspaces(sessions)
    self.workspaces = workspaces
    self.onCreated = onCreated
    self.onStartFailed = onStartFailed
    _state = State(
      initialValue: DashboardTerminalAgentCreateState(defaultSessionID: workspaces.first?.sessionId)
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      Form {
        workspaceSection
        runtimeSection
        identitySection
        if let issue = state.issue {
          Section {
            Label(issue.withoutTrailingPeriod, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(HarnessMonitorTheme.danger)
          }
        }
      }
      .formStyle(.grouped)
      Divider()
      footer
    }
    .frame(minWidth: 620, idealWidth: 680, minHeight: 560, idealHeight: 620)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardTerminalCreateSheet)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text("New terminal agent").scaledFont(.title2.weight(.semibold))
      Text("Start a managed terminal in a selected project and worktree")
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
      .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardTerminalWorkspacePicker)
      if let session = selectedSession {
        Text(session.checkoutRoot)
          .scaledFont(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
    }
  }

  private var runtimeSection: some View {
    Section("Runtime") {
      Picker("Terminal runtime", selection: $state.runtime) {
        ForEach(AgentTuiRuntime.allCases) { runtime in
          Text(runtime.title).tag(runtime)
        }
      }
      .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardTerminalRuntimePicker)
      Text("Harness keeps the terminal process attached to its managed identity")
        .scaledFont(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var identitySection: some View {
    Section("Agent") {
      TextField("Agent name (optional)", text: $state.name)
        .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardTerminalNameField)
      TextEditor(text: $state.prompt)
        .frame(minHeight: 100, maxHeight: 160)
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary) }
        .accessibilityLabel("Initial prompt (optional)")
        .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardTerminalPromptField)
      Text("An initial prompt is optional and is sent after the terminal is ready")
        .scaledFont(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var footer: some View {
    HStack {
      Button("Cancel", role: .cancel) { dismiss() }
        .keyboardShortcut(.cancelAction)
        .disabled(state.isStarting)
      Spacer()
      Button("Start agent") { startAgent() }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(selectedSession == nil || !state.canStart)
        .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardTerminalStartButton)
    }
    .padding(16)
  }

  private static func uniqueWorkspaces(_ sessions: [SessionSummary]) -> [SessionSummary] {
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

  private func startAgent() {
    guard let session = selectedSession, state.beginStart() else { return }
    let request = AgentTuiStartRequest(
      runtime: state.runtime.rawValue,
      name: state.name,
      prompt: state.prompt,
      projectDir: session.checkoutRoot,
      rows: 32,
      cols: 120
    )
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Starting Dashboard terminal agent") {
        let outcome = await store.startDashboardTerminalAgent(
          sessionID: session.sessionId,
          request: request
        )
        await state.finishStart(outcome)
        guard let snapshot = outcome.snapshot else {
          await MainActor.run { onStartFailed() }
          return
        }
        await MainActor.run {
          onCreated(snapshot, session)
          dismiss()
        }
      }
    )
  }
}

@MainActor
@Observable
private final class DashboardTerminalAgentCreateState {
  var selectedSessionID: String
  var runtime: AgentTuiRuntime = .codex
  var name = ""
  var prompt = ""
  private(set) var isStarting = false
  private(set) var requiresAgentListReview = false
  private(set) var issue: String?

  var canStart: Bool { !isStarting && !requiresAgentListReview }

  init(defaultSessionID: String?) {
    selectedSessionID = defaultSessionID ?? ""
  }

  func beginStart() -> Bool {
    guard canStart else { return false }
    isStarting = true
    issue = nil
    return true
  }

  func finishStart(_ outcome: DashboardTerminalStartOutcome) {
    isStarting = false
    switch outcome {
    case .started:
      issue = nil
    case .rejected(let message):
      issue = message.withoutTrailingPeriod
    case .unknown:
      requiresAgentListReview = true
      issue =
        "The start outcome is unknown. Close this sheet and review the refreshed agent list "
        + "before retrying"
    }
  }
}
