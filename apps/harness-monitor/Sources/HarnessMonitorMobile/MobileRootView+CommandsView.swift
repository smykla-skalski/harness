import SwiftUI

struct CommandsView: View {
  @Environment(MobileMonitorStore.self)
  private var store
  @State private var composerPresented = false

  var body: some View {
    NavigationStack {
      List {
        Section {
          StationPicker()
        }
        Section("Queue") {
          if store.commandsForSelectedStation.isEmpty {
            ContentUnavailableView(
              "No queued commands",
              systemImage: "terminal",
              description: Text("Signed commands and receipts appear here.")
            )
          } else {
            ForEach(store.commandsForSelectedStation) { command in
              CommandRow(command: command)
            }
          }
        }
      }
      .navigationTitle("Commands")
      .toolbar {
        Button {
          composerPresented = true
        } label: {
          Label("New Command", systemImage: "plus")
        }
        .disabled(store.snapshot.stations.isEmpty)
      }
      .sheet(isPresented: $composerPresented) {
        MobileCommandComposerView(initialStationID: store.selectedStationID)
      }
    }
  }
}

struct CommandRow: View {
  @Environment(MobileMonitorStore.self)
  private var store
  let command: MobileCommandRecord

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label(command.kind.title, systemImage: iconName)
          .font(.headline)
        Spacer()
        Text(command.status.title)
          .font(.caption.weight(.semibold))
          .foregroundStyle(statusColor)
      }
      Text(command.confirmationText)
        .font(.subheadline)
        .foregroundStyle(.secondary)
      if let receipt = command.receipt {
        Text(receipt.message)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      HStack {
        if command.status == .failed || command.status == .expired {
          Button {
            Task { await store.retry(command) }
          } label: {
            Label("Retry", systemImage: "arrow.clockwise")
          }
          .harnessActionButtonStyle()
        }
        if command.status == .queued {
          Button(role: .destructive) {
            Task { await store.cancel(command) }
          } label: {
            Label("Cancel", systemImage: "xmark")
          }
          .harnessActionButtonStyle()
        }
      }
      .font(.caption)
    }
    .padding(.vertical, 4)
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
