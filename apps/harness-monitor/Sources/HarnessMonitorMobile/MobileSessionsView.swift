import HarnessMonitorCore
import SwiftUI

struct SessionsView: View {
  @Environment(MobileMonitorStore.self)
  private var store

  var body: some View {
    NavigationStack {
      List {
        Section {
          StationPicker()
        }
        Section("Sessions") {
          if store.sessionsForSelectedStation.isEmpty {
            ContentUnavailableView(
              "No mirrored sessions",
              systemImage: "rectangle.stack",
              description: Text("Live Harness sessions from the selected Mac appear here.")
            )
          } else {
            ForEach(store.sessionsForSelectedStation) { session in
              NavigationLink {
                SessionDetailView(sessionID: session.id)
              } label: {
                SessionRow(session: session)
              }
            }
          }
        }
      }
      .navigationTitle("Sessions")
    }
  }
}

struct SessionRow: View {
  let session: MobileSessionSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Text(session.title)
          .font(.headline)
        Spacer()
        Text(session.status)
          .font(.caption.weight(.semibold))
          .foregroundStyle(session.blockedAgentCount > 0 ? .orange : .secondary)
      }
      Text("\(session.projectName)  \(session.branch)")
        .font(.caption)
        .foregroundStyle(.secondary)
      if !session.summary.isEmpty {
        Text(session.summary)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      HStack(spacing: 14) {
        Label("\(session.activeAgentCount)", systemImage: "person.2")
        Label("\(session.blockedAgentCount)", systemImage: "exclamationmark.triangle")
        if !session.agents.isEmpty {
          Label("\(session.agents.count)", systemImage: "cpu")
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
  }
}

struct SessionDetailView: View {
  @Environment(MobileMonitorStore.self)
  private var store
  let sessionID: String

  @State private var promptAgent: MobileAgentSummary?
  @State private var composerPresented = false

  private var session: MobileSessionSummary? {
    store.snapshot.sessions.first { $0.id == sessionID }
  }

  var body: some View {
    List {
      if let session {
        Section("Session") {
          VStack(alignment: .leading, spacing: 8) {
            Text(session.title)
              .font(.headline)
            Text("\(session.projectName)  \(session.branch)")
              .font(.subheadline)
              .foregroundStyle(.secondary)
            if !session.summary.isEmpty {
              Text(session.summary)
                .font(.body)
            }
          }
          HStack {
            Label(session.status, systemImage: "circle.dotted")
            Spacer()
            Text(session.lastActivityAt, style: .relative)
              .foregroundStyle(.secondary)
          }
          .font(.caption)
        }

        Section("Agents") {
          if session.agents.isEmpty {
            ContentUnavailableView(
              "No mirrored agents",
              systemImage: "cpu",
              description: Text("Managed terminal, Codex, and ACP agents appear here.")
            )
          } else {
            ForEach(session.agents) { agent in
              MobileAgentRow(
                agent: agent,
                canQueueCommands: store.canQueueCommand(stationID: agent.stationID),
                prompt: { promptAgent = agent },
                stop: {
                  Task {
                    await store.queueCommand(
                      agent.stopDraft(targetRevision: store.snapshot.revision)
                    )
                  }
                }
              )
            }
          }
        }
      } else {
        ContentUnavailableView(
          "Session no longer mirrored",
          systemImage: "rectangle.stack.badge.minus",
          description: Text("Refresh to load the latest station state.")
        )
      }
    }
    .navigationTitle("Session")
    .toolbar {
      Button {
        composerPresented = true
      } label: {
        Label("Start Agent", systemImage: "plus")
      }
      .disabled(session == nil)
    }
    .sheet(item: $promptAgent) { agent in
      MobileAgentPromptSheet(agent: agent) { prompt in
        Task {
          await store.queueCommand(
            agent.promptDraft(prompt: prompt, targetRevision: store.snapshot.revision)
          )
        }
      }
    }
    .sheet(isPresented: $composerPresented) {
      MobileCommandComposerView(
        initialStationID: session?.stationID ?? store.selectedStationID,
        initialKind: .agentStart,
        initialSessionID: sessionID
      )
    }
  }
}

struct MobileAgentRow: View {
  let agent: MobileAgentSummary
  let canQueueCommands: Bool
  let prompt: () -> Void
  let stop: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Label(agent.displayName, systemImage: iconName)
          .font(.headline)
        Spacer()
        Text(agent.status)
          .font(.caption.weight(.semibold))
          .foregroundStyle(agent.isBlocked ? .orange : .secondary)
      }
      Text(agent.family.title)
        .font(.caption)
        .foregroundStyle(.secondary)
      if !agent.summary.isEmpty {
        Text(agent.summary)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      HStack(spacing: 12) {
        if agent.pendingApprovalCount > 0 {
          Label("\(agent.pendingApprovalCount) approvals", systemImage: "checkmark.seal")
        }
        if agent.pendingPermissionCount > 0 {
          Label("\(agent.pendingPermissionCount) permissions", systemImage: "lock.shield")
        }
        Text(agent.lastActivityAt, style: .relative)
      }
      .font(.caption2)
      .foregroundStyle(.secondary)

      if canQueueCommands {
        HStack(spacing: 8) {
          Button(action: prompt) {
            Label("Prompt", systemImage: "text.bubble")
          }
          .harnessActionButtonStyle()

          Button(role: .destructive, action: stop) {
            Label("Stop", systemImage: "stop.circle")
          }
          .harnessActionButtonStyle()
          .disabled(!agent.isActive)
        }
        .font(.caption)
      }
    }
    .padding(.vertical, 4)
  }

  private var iconName: String {
    switch agent.family {
    case .terminal:
      "terminal"
    case .codex:
      "sparkles"
    case .acp:
      "lock.shield"
    }
  }
}

struct MobileAgentPromptSheet: View {
  @Environment(\.dismiss)
  private var dismiss
  let agent: MobileAgentSummary
  let onSubmit: (String) -> Void

  @State private var prompt = ""

  var body: some View {
    NavigationStack {
      Form {
        Section("Agent") {
          Text(agent.displayName)
          Text(agent.status)
            .foregroundStyle(.secondary)
        }
        Section("Prompt") {
          TextField("Prompt", text: $prompt, axis: .vertical)
            .lineLimit(4...8)
        }
      }
      .navigationTitle("Prompt Agent")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Queue") {
            onSubmit(prompt)
            dismiss()
          }
          .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }
  }
}
