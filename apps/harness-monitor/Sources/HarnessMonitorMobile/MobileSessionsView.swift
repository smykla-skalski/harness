import HarnessMonitorCore
import HarnessMonitorMirrorStore
import SwiftUI

struct SessionsView: View {
  @Environment(MirrorStore.self)
  private var store
  @State private var searchText = ""

  var body: some View {
    NavigationStack {
      List {
        Section {
          StationPicker()
        }
        Section("Sessions") {
          if filteredSessions.isEmpty {
            ContentUnavailableView(
              "No mirrored sessions",
              systemImage: "rectangle.stack",
              description: Text("Live Harness sessions from the selected Mac appear here")
            )
          } else {
            ForEach(filteredSessions) { session in
              NavigationLink {
                SessionDetailView(sessionID: session.id)
              } label: {
                SessionRow(session: session)
              }
              .harnessBalancedListSeparator()
            }
          }
        }
        if !filteredTaskBoard.isEmpty {
          Section("Task board") {
            ForEach(filteredTaskBoard) { item in
              MobileTaskBoardRow(item: item)
            }
          }
        }
      }
      .harnessMonitorListChrome()
      .navigationTitle("Sessions")
      .searchable(text: $searchText, prompt: "Search sessions")
    }
  }

  private var filteredSessions: [MobileSessionSummary] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      return store.sessionsForSelectedStation
    }
    return store.sessionsForSelectedStation.filter {
      $0.title.localizedCaseInsensitiveContains(query)
        || $0.projectName.localizedCaseInsensitiveContains(query)
        || $0.branch.localizedCaseInsensitiveContains(query)
        || $0.summary.localizedCaseInsensitiveContains(query)
    }
  }

  private var filteredTaskBoard: [MobileTaskBoardSummary] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      return store.taskBoardForSelectedStation
    }
    return store.taskBoardForSelectedStation.filter {
      $0.title.localizedCaseInsensitiveContains(query)
        || $0.bodyPreview.localizedCaseInsensitiveContains(query)
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
          .lineLimit(2)
          .layoutPriority(1)
          .fixedSize(horizontal: false, vertical: true)
        Spacer()
        Text(session.status)
          .harnessStatusBadge(session.blockedAgentCount > 0 ? .orange : .blue)
          .fixedSize(horizontal: true, vertical: false)
      }
      Text("\(session.projectName)  \(session.branch)")
        .font(.caption)
        .foregroundStyle(.secondary)
      if !session.summary.isEmpty {
        Text(session.summary)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      HStack(spacing: 13) {
        HarnessCompactIconText(
          title: String(localized: "\(session.activeAgentCount) agents"),
          systemImage: "person.2",
          spacing: 3
        )
        HarnessCompactIconText(
          title: String(localized: "\(session.blockedAgentCount) waiting"),
          systemImage: "exclamationmark.triangle",
          spacing: 3
        )
        if !session.agents.isEmpty {
          HarnessCompactIconText(
            title: String(localized: "\(session.agents.count) mirrored"),
            systemImage: "cpu",
            spacing: 3
          )
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
    .harnessBalancedListSeparator()
    .accessibilityElement(children: .combine)
  }
}

/// Typed navigation route for opening a mirrored session's detail. Used by the
/// Today attention list so a blocked-agent or ACP-decision item opens the session
/// it is waiting on. `sourceID` names the tapped row's zoom-transition source so two
/// attention items pointing at one session do not collide on a shared id.
struct MobileSessionDetailRoute: Hashable {
  let sessionID: String
  let sourceID: String
}

struct SessionDetailView: View {
  @Environment(MirrorStore.self)
  private var store
  let sessionID: String

  @State private var promptAgent: MobileAgentSummary?
  @State private var composerPresented = false
  @State private var pendingConfirmation: PendingCommandConfirmation?
  @Namespace private var zoomNamespace

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
            HarnessCompactIconText(title: session.status, systemImage: "circle.dotted")
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
              description: Text("Managed terminal, Codex, and ACP agents appear here")
            )
          } else {
            ForEach(session.agents) { agent in
              MobileAgentRow(
                agent: agent,
                canQueueCommands: store.canQueueCommand(stationID: agent.stationID),
                zoomNamespace: zoomNamespace,
                prompt: { promptAgent = agent },
                stop: {
                  confirmCommandIfNeeded(
                    kind: .agentStop,
                    message: String(localized: "Stop \(agent.displayName)?"),
                    pending: $pendingConfirmation
                  ) {
                    Task {
                      await store.queueCommand(
                        agent.stopDraft(targetRevision: store.snapshot.revision)
                      )
                    }
                  }
                }
              )
              .harnessBalancedListSeparator()
            }
          }
        }
      } else {
        ContentUnavailableView(
          "Session no longer mirrored",
          systemImage: "rectangle.stack.badge.minus",
          description: Text("Refresh to load the latest station state")
        )
      }
    }
    .harnessMonitorListChrome()
    .navigationTitle("Session")
    .toolbar {
      Button {
        composerPresented = true
      } label: {
        Label("Start Agent", systemImage: "plus")
      }
      .disabled(session == nil)
      .matchedTransitionSource(id: "composer", in: zoomNamespace)
    }
    .sheet(item: $promptAgent) { agent in
      MobileAgentPromptSheet(agent: agent) { prompt in
        Task {
          await store.queueCommand(
            agent.promptDraft(prompt: prompt, targetRevision: store.snapshot.revision)
          )
        }
      }
      .navigationTransition(.zoom(sourceID: agent.id, in: zoomNamespace))
    }
    .sheet(isPresented: $composerPresented) {
      MobileCommandComposerView(
        store: store,
        initialStationID: session?.stationID ?? store.selectedStationID,
        initialKind: .agentStart,
        initialSessionID: sessionID
      )
      .navigationTransition(.zoom(sourceID: "composer", in: zoomNamespace))
    }
    .commandConfirmation($pendingConfirmation)
  }
}

struct MobileAgentRow: View {
  let agent: MobileAgentSummary
  let canQueueCommands: Bool
  let zoomNamespace: Namespace.ID
  let prompt: () -> Void
  let stop: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline) {
          HarnessCompactIconText(title: agent.displayName, systemImage: iconName)
            .font(.headline)
            .lineLimit(2)
            .layoutPriority(1)
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
            HarnessCompactIconText(
              title: String(localized: "\(agent.pendingApprovalCount) approvals"),
              systemImage: "checkmark.seal",
              spacing: 3
            )
          }
          if agent.pendingPermissionCount > 0 {
            HarnessCompactIconText(
              title: String(localized: "\(agent.pendingPermissionCount) permissions"),
              systemImage: "lock.shield",
              spacing: 3
            )
          }
          Text(agent.lastActivityAt, style: .relative)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .combine)

      if canQueueCommands {
        HarnessMonitorMobileGlassControlGroup(spacing: 8) {
          HStack(spacing: 8) {
            Button(action: prompt) {
              Label("Prompt", systemImage: "text.bubble")
            }
            .harnessActionButtonStyle()
            .matchedTransitionSource(id: agent.id, in: zoomNamespace)

            Button(role: .destructive, action: stop) {
              Label("Stop", systemImage: "stop.circle")
            }
            .harnessActionButtonStyle()
            .disabled(!agent.isActive)
          }
          .font(.caption)
        }
      }
    }
    .padding(.vertical, 4)
    .harnessBalancedListSeparator()
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
