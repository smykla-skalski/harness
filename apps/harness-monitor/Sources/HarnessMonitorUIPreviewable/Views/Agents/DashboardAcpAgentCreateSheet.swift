import HarnessMonitorKit
import Observation
import SwiftUI

struct DashboardAcpAgentCreateSheet: View {
  let store: HarnessMonitorStore
  let sessions: [SessionSummary]
  let onCreated: (AcpAgentSnapshot, SessionSummary) -> Void
  @Environment(\.dismiss)
  private var dismiss
  @State private var state = DashboardAcpAgentCreateState()

  init(
    store: HarnessMonitorStore,
    sessions: [SessionSummary],
    initialDescriptors: [AcpAgentDescriptor] = [],
    initialProbes: [AcpRuntimeProbe] = [],
    onCreated: @escaping (AcpAgentSnapshot, SessionSummary) -> Void
  ) {
    self.store = store
    self.sessions = sessions
    self.onCreated = onCreated
    _state = State(
      initialValue: DashboardAcpAgentCreateState(
        descriptors: initialDescriptors,
        probes: initialProbes,
        defaultSessionID: sessions.first?.sessionId
      )
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("New ACP agent").scaledFont(.title2.weight(.semibold))
          Text("Start a catalog agent in a selected project and worktree")
            .scaledFont(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(20)
      Divider()

      Form {
        Section("Workspace") {
          Picker("Project and worktree", selection: $state.selectedSessionID) {
            ForEach(workspaces) { session in
              Text("\(session.projectName) — \(session.checkoutDisplayName)")
                .tag(session.sessionId)
            }
          }
          if let session = selectedSession {
            Text(session.checkoutRoot)
              .scaledFont(.caption)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
        }

        Section("Provider") {
          if state.isLoadingCatalog {
            ProgressView("Loading ACP catalog")
          } else if state.descriptors.isEmpty {
            ContentUnavailableView(
              "No ACP providers available",
              systemImage: "shippingbox",
              description: Text("The connected daemon did not report an ACP catalog")
            )
          } else {
            Picker("Provider", selection: $state.selectedDescriptorID) {
              ForEach(state.descriptors) { descriptor in
                Text(descriptor.displayName).tag(descriptor.id)
              }
            }
            if let descriptor = selectedDescriptor {
              DashboardAcpProviderReadiness(
                descriptor: descriptor,
                probe: selectedProbe
              )
            }
          }
        }

        Section("First prompt") {
          TextField("Agent name", text: $state.name)
          TextEditor(text: $state.prompt)
            .frame(minHeight: 100, maxHeight: 180)
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary) }
          Text("The prompt is optional and can also be sent from agent detail")
            .scaledFont(.caption)
            .foregroundStyle(.secondary)
        }

        if let issue = state.issue {
          Section {
            Label(issue.withoutTrailingPeriod, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(HarnessMonitorTheme.danger)
          }
        }
      }
      .formStyle(.grouped)

      Divider()
      HStack {
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button("Start agent") { startAgent() }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(!canStart)
      }
      .padding(16)
    }
    .frame(minWidth: 620, idealWidth: 680, minHeight: 570, idealHeight: 640)
    .task { loadCatalog() }
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

  private var selectedDescriptor: AcpAgentDescriptor? {
    state.descriptors.first { $0.id == state.selectedDescriptorID }
  }

  private var selectedProbe: AcpRuntimeProbe? {
    state.probes.first { $0.agentId == state.selectedDescriptorID }
  }

  private var canStart: Bool {
    !state.isStarting && selectedSession != nil && selectedDescriptor != nil
      && selectedProbe?.authState != .unavailable
      && selectedProbe?.binaryPresent != false
  }

  private func loadCatalog() {
    guard state.beginCatalogLoad(defaultSessionID: workspaces.first?.sessionId) else { return }
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Loading Dashboard ACP catalog") {
        async let descriptors = store.fetchAcpAgentDescriptors()
        async let probes = store.fetchRuntimeProbeResults()
        await state.finishCatalogLoad(descriptors: descriptors, probes: probes)
      }
    )
  }

  private func startAgent() {
    guard let session = selectedSession, let descriptor = selectedDescriptor else { return }
    let name = state.name
    let prompt = state.prompt
    guard state.beginStart() else { return }
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Starting Dashboard ACP agent") {
        let snapshot = await store.startDashboardAcpAgent(
          descriptorID: descriptor.descriptorIdentity,
          sessionID: session.sessionId,
          projectDirectory: session.checkoutRoot,
          name: name,
          prompt: prompt
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
}

private struct DashboardAcpProviderReadiness: View {
  let descriptor: AcpAgentDescriptor
  let probe: AcpRuntimeProbe?

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Label(binaryText, systemImage: binaryIcon)
      Label(authText, systemImage: authIcon)
      if let version = probe?.version {
        Text("Version \(version)")
      }
      if let hint = probe?.installHint ?? descriptor.installHint,
        probe?.binaryPresent == false
      {
        Text(hint.withoutTrailingPeriod).textSelection(.enabled)
      }
    }
    .scaledFont(.caption)
    .foregroundStyle(.secondary)
  }

  private var binaryText: String {
    switch probe?.binaryPresent {
    case true: "Provider binary available"
    case false: "Provider binary unavailable"
    case nil: "Provider binary has not been checked"
    }
  }

  private var binaryIcon: String {
    probe?.binaryPresent == true ? "checkmark.circle.fill" : "exclamationmark.circle"
  }

  private var authText: String {
    switch probe?.authState {
    case .ready: "Authentication ready"
    case .unknown: "Authentication not verified"
    case .unavailable: "Authentication unavailable"
    case nil: "Authentication has not been checked"
    }
  }

  private var authIcon: String {
    probe?.authState == .ready
      ? "person.badge.shield.checkmark"
      : "person.badge.shield.exclamationmark"
  }
}

@MainActor
@Observable
private final class DashboardAcpAgentCreateState {
  var selectedSessionID = ""
  var selectedDescriptorID = ""
  var name = ""
  var prompt = ""
  private(set) var descriptors: [AcpAgentDescriptor] = []
  private(set) var probes: [AcpRuntimeProbe] = []
  private(set) var isLoadingCatalog = false
  private(set) var isStarting = false
  private(set) var issue: String?
  private var hasLoadedCatalog = false

  init(
    descriptors: [AcpAgentDescriptor] = [],
    probes: [AcpRuntimeProbe] = [],
    defaultSessionID: String? = nil
  ) {
    self.descriptors = descriptors
    self.probes = probes
    selectedSessionID = defaultSessionID ?? ""
    selectedDescriptorID = descriptors.first?.id ?? ""
    hasLoadedCatalog = !descriptors.isEmpty
  }

  func beginCatalogLoad(defaultSessionID: String?) -> Bool {
    guard !hasLoadedCatalog, !isLoadingCatalog else { return false }
    selectedSessionID = defaultSessionID ?? ""
    isLoadingCatalog = true
    return true
  }

  func finishCatalogLoad(
    descriptors: [AcpAgentDescriptor],
    probes: AcpRuntimeProbeResponse?
  ) {
    self.descriptors = descriptors.sorted { $0.displayName < $1.displayName }
    self.probes = probes?.probes ?? []
    selectedDescriptorID = self.descriptors.first?.id ?? ""
    isLoadingCatalog = false
    hasLoadedCatalog = true
    issue = descriptors.isEmpty ? "The connected daemon returned an empty ACP catalog" : nil
  }

  func beginStart() -> Bool {
    guard !isStarting else { return false }
    isStarting = true
    issue = nil
    return true
  }

  func finishStart(succeeded: Bool) {
    isStarting = false
    if !succeeded { issue = "The daemon did not start the ACP agent" }
  }
}
