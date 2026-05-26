import HarnessMonitorCore
import HarnessMonitorMirrorStore
import SwiftUI

struct CommandsView: View {
  @Environment(MirrorStore.self)
  private var store
  @State private var composerPresented = false
  @State private var searchText = ""
  @Namespace private var zoomNamespace

  var body: some View {
    NavigationStack {
      List {
        Section {
          StationPicker()
        }
        Section("Queue") {
          if activeCommands.isEmpty {
            ContentUnavailableView(
              "No queued commands",
              systemImage: "terminal",
              description: Text("Signed commands and receipts appear here.")
            )
          } else {
            ForEach(activeCommands) { command in
              NavigationLink {
                CommandDetailView(commandID: command.id)
              } label: {
                CommandRow(command: command)
              }
              .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                CommandSwipeActions(command: command)
              }
            }
          }
        }
        if !receiptCommands.isEmpty {
          Section("Receipts") {
            ForEach(receiptCommands) { command in
              NavigationLink {
                CommandDetailView(commandID: command.id)
              } label: {
                CommandRow(command: command)
              }
              .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                CommandSwipeActions(command: command)
              }
            }
          }
        }
      }
      .harnessMonitorListChrome()
      .navigationTitle("Commands")
      .searchable(text: $searchText, prompt: "Search commands")
      .toolbar {
        Button {
          composerPresented = true
        } label: {
          Label("New Command", systemImage: "plus")
        }
        .disabled(store.snapshot.stations.isEmpty)
        .matchedTransitionSource(id: "composer", in: zoomNamespace)
      }
      .sheet(isPresented: $composerPresented) {
        MobileCommandComposerView(store: store, initialStationID: store.selectedStationID)
          .navigationTransition(.zoom(sourceID: "composer", in: zoomNamespace))
      }
    }
  }

  private var activeCommands: [MobileCommandRecord] {
    matching(store.commandsForSelectedStation.filter { !$0.status.isTerminal })
  }

  private var receiptCommands: [MobileCommandRecord] {
    matching(store.commandsForSelectedStation.filter(\.status.isTerminal))
  }

  private func matching(_ commands: [MobileCommandRecord]) -> [MobileCommandRecord] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      return commands
    }
    return commands.filter {
      $0.title.localizedCaseInsensitiveContains(query)
        || $0.kind.title.localizedCaseInsensitiveContains(query)
        || $0.confirmationText.localizedCaseInsensitiveContains(query)
    }
  }
}

struct CommandRow: View {
  let command: MobileCommandRecord

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        HarnessCompactIconText(title: command.title, systemImage: iconName)
          .font(.headline)
          .lineLimit(2)
          .layoutPriority(1)
        Spacer()
        Text(command.status.title)
          .harnessStatusBadge(statusColor)
      }
      VStack(alignment: .leading, spacing: 3) {
        Text(command.kind.title)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(command.confirmationText)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      if let receipt = command.receipt {
        Text(receipt.message)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
    .harnessBalancedListSeparator()
    .accessibilityElement(children: .combine)
  }

  var iconName: String {
    switch command.kind {
    case .pullRequestMerge: "arrow.merge"
    case .pullRequestApprove: "checkmark.seal"
    case .pullRequestLabel: "tag"
    case .pullRequestRerunChecks: "arrow.clockwise"
    case .acpPermissionDecision: "lock.shield"
    case .taskBoardDispatch, .taskBoardPlanApproval: "list.bullet.clipboard"
    case .agentStart: "play.circle"
    case .agentStop: "stop.circle"
    case .agentPrompt: "text.bubble"
    case .refresh: "arrow.triangle.2.circlepath"
    }
  }

  var statusColor: Color {
    switch command.status {
    case .succeeded: .green
    case .failed, .expired, .cancelled: .red
    case .running: .blue
    case .draft, .queued, .accepted: .orange
    }
  }
}

struct CommandSwipeActions: View {
  @Environment(MirrorStore.self)
  private var store
  let command: MobileCommandRecord

  var body: some View {
    if command.status == .failed || command.status == .expired {
      Button {
        Task { await store.retry(command) }
      } label: {
        Label("Retry", systemImage: "arrow.clockwise")
      }
      .tint(command.statusColor)
    }
    if command.status == .queued {
      Button(role: .destructive) {
        Task { await store.cancel(command) }
      } label: {
        Label("Cancel", systemImage: "xmark")
      }
    }
  }
}

struct CommandDetailView: View {
  @Environment(MirrorStore.self)
  private var store
  let commandID: String

  private var command: MobileCommandRecord? {
    store.snapshot.commands.first { $0.id == commandID }
  }

  var body: some View {
    List {
      if let command {
        Section("Summary") {
          LabeledContent("Status") {
            Text(command.status.title)
              .harnessStatusBadge(command.statusColor)
          }
          .harnessBalancedListSeparator()
          LabeledContent("Family", value: command.kind.title)
            .harnessBalancedListSeparator()
          LabeledContent("Risk", value: command.risk.title)
            .harnessBalancedListSeparator()
          LabeledContent("Station", value: stationName(for: command.stationID))
            .harnessBalancedListSeparator()
          LabeledContent("Actor", value: command.actorDeviceID)
            .harnessBalancedListSeparator()
          LabeledContent("Target revision", value: "\(command.target.targetRevision)")
            .harnessBalancedListSeparator()
          LabeledContent(
            "Created", value: command.createdAt.formatted(date: .abbreviated, time: .shortened)
          )
          .harnessBalancedListSeparator()
          LabeledContent(
            "Updated", value: command.updatedAt.formatted(date: .abbreviated, time: .shortened)
          )
          .harnessBalancedListSeparator()
          LabeledContent(
            "Expires", value: command.expiresAt.formatted(date: .abbreviated, time: .shortened)
          )
          .harnessBalancedListSeparator()
        }
        Section("Confirmation") {
          Text(command.confirmationText)
            .harnessBalancedListSeparator()
          if let auditReason = command.auditReason,
            !auditReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          {
            LabeledContent("Audit reason", value: auditReason)
              .harnessBalancedListSeparator()
          }
        }
        Section("Target") {
          CommandDetailOptionalRow(title: "Session", value: command.target.sessionID)
          CommandDetailOptionalRow(title: "Agent", value: command.target.agentID)
          CommandDetailOptionalRow(title: "Review", value: command.target.reviewID)
          CommandDetailOptionalRow(title: "Task", value: command.target.taskID)
        }
        if !command.payload.isEmpty {
          Section("Payload") {
            ForEach(command.payload.sorted(by: { $0.key < $1.key }), id: \.key) { item in
              LabeledContent(item.key, value: item.value)
                .harnessBalancedListSeparator()
            }
          }
        }
        Section("Immutable Receipt") {
          if let receipt = command.receipt {
            LabeledContent("Status", value: receipt.status.title)
              .harnessBalancedListSeparator()
            Text(receipt.message)
              .foregroundStyle(.secondary)
              .harnessBalancedListSeparator()
            LabeledContent(
              "Received", value: receipt.receivedAt.formatted(date: .abbreviated, time: .shortened)
            )
            .harnessBalancedListSeparator()
            if let completedAt = receipt.completedAt {
              LabeledContent(
                "Completed", value: completedAt.formatted(date: .abbreviated, time: .shortened)
              )
              .harnessBalancedListSeparator()
            }
            LabeledContent("Execution revision", value: "\(receipt.executionRevision)")
              .harnessBalancedListSeparator()
          } else {
            Label("No receipt yet", systemImage: "clock")
              .foregroundStyle(.secondary)
              .harnessBalancedListSeparator()
          }
        }
        if command.canShowDetailActions {
          Section("Actions") {
            CommandDetailActions(command: command)
              .harnessBalancedListSeparator()
          }
        }
      } else {
        ContentUnavailableView(
          "Command no longer mirrored",
          systemImage: "terminal.badge.minus",
          description: Text("Refresh to load the latest command queue.")
        )
      }
    }
    .harnessMonitorListChrome()
    .navigationTitle("Command")
  }

  private func stationName(for stationID: String) -> String {
    store.snapshot.station(id: stationID)?.displayName ?? stationID
  }
}

struct CommandDetailOptionalRow: View {
  let title: String
  let value: String?

  var body: some View {
    if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      LabeledContent(title, value: value)
        .harnessBalancedListSeparator()
    }
  }
}

struct CommandDetailActions: View {
  @Environment(MirrorStore.self)
  private var store
  let command: MobileCommandRecord

  var body: some View {
    GlassEffectContainer(spacing: 8) {
      HStack(spacing: 8) {
        if command.status == .failed || command.status == .expired {
          Button {
            Task { await store.retry(command) }
          } label: {
            Label("Retry", systemImage: "arrow.clockwise")
          }
          .harnessActionButtonStyle(prominent: true, tint: command.statusColor)
        }
        if command.status == .queued {
          Button(role: .destructive) {
            Task { await store.cancel(command) }
          } label: {
            Label("Cancel", systemImage: "xmark")
          }
          .harnessActionButtonStyle(tint: .red)
        }
      }
      .padding(.vertical, 3)
    }
  }
}

extension MobileCommandRecord {
  fileprivate var canShowDetailActions: Bool {
    status == .failed || status == .expired || status == .queued
  }

  fileprivate var statusColor: Color {
    switch status {
    case .succeeded: .green
    case .failed, .expired, .cancelled: .red
    case .running: .blue
    case .draft, .queued, .accepted: .orange
    }
  }
}

extension MobileCommandRisk {
  fileprivate var title: String {
    switch self {
    case .low: "Low"
    case .high: "High"
    case .destructive: "Destructive"
    }
  }
}
