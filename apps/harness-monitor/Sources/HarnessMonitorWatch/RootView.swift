import HarnessMonitorCore
import SwiftUI
import WidgetKit

struct RootView: View {
  @Environment(WatchMonitorStore.self) private var store
  @State private var pendingAttention: MobileAttentionItem?
  @State private var pendingCancellation: MobileCommandRecord?
  @State private var composerPresented = false

  var body: some View {
    @Bindable var store = store
    NavigationStack {
      List {
        Section {
          WatchStatusRow(status: store.status)
        }
        Section("Needs You") {
          if store.snapshot.sortedAttention.isEmpty {
            Label("Clear", systemImage: "checkmark.circle")
          } else {
            ForEach(store.snapshot.sortedAttention.prefix(6)) { item in
              WatchAttentionRow(item: item) {
                pendingAttention = item
              }
            }
          }
        }
        Section("Commands") {
          Button {
            composerPresented = true
          } label: {
            Label("New Command", systemImage: "plus.circle")
          }
          .disabled(store.snapshot.stations.isEmpty)
          if store.snapshot.stations.count > 1 {
            Picker("Station", selection: $store.selectedStationID) {
              ForEach(store.snapshot.stations) { station in
                Text(station.displayName).tag(station.id)
              }
            }
          }
          ForEach(store.commandsForSelectedStation.prefix(4)) { command in
            WatchCommandRow(command: command) {
              pendingCancellation = command
            }
          }
        }
      }
      .navigationTitle("Harness")
      .refreshable {
        await store.refresh()
      }
      .task {
        WidgetCenter.shared.reloadAllTimelines()
        await store.load()
      }
      .confirmationDialog(
        pendingAttention?.commandKind?.title ?? "Confirm",
        isPresented: Binding(
          get: { pendingAttention != nil },
          set: { if !$0 { pendingAttention = nil } }
        ),
        titleVisibility: .visible
      ) {
        Button("Confirm") {
          guard let pendingAttention else {
            return
          }
          Task {
            await store.queueCommand(from: pendingAttention)
            self.pendingAttention = nil
          }
        }
        Button("Cancel", role: .cancel) {
          pendingAttention = nil
        }
      }
      .confirmationDialog(
        "Cancel Command",
        isPresented: Binding(
          get: { pendingCancellation != nil },
          set: { if !$0 { pendingCancellation = nil } }
        ),
        titleVisibility: .visible
      ) {
        Button("Cancel Command", role: .destructive) {
          guard let pendingCancellation else {
            return
          }
          Task {
            await store.cancel(pendingCancellation)
            self.pendingCancellation = nil
          }
        }
        Button("Keep Queued", role: .cancel) {
          pendingCancellation = nil
        }
      } message: {
        Text(pendingCancellation?.confirmationText ?? "")
      }
      .sheet(isPresented: $composerPresented) {
        NavigationStack {
          WatchCommandComposerView(initialStationID: store.selectedStationID)
        }
      }
    }
  }
}

struct WatchCommandRow: View {
  let command: MobileCommandRecord
  let cancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: symbol)
          .foregroundStyle(color)
        VStack(alignment: .leading, spacing: 2) {
          Text(command.title)
            .font(.headline)
          Text(command.status.title)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      if let receipt = command.receipt {
        Text(receipt.message)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      if command.status == .queued {
        Button(role: .destructive, action: cancel) {
          Label("Cancel", systemImage: "xmark")
        }
      }
    }
  }

  private var symbol: String {
    switch command.status {
    case .succeeded:
      "checkmark.circle"
    case .failed, .expired:
      "xmark.octagon"
    case .cancelled:
      "xmark.circle"
    case .running:
      "play.circle"
    case .draft, .queued, .accepted:
      "clock"
    }
  }

  private var color: Color {
    switch command.status {
    case .succeeded:
      .green
    case .failed, .expired, .cancelled:
      .red
    case .running:
      .blue
    case .draft, .queued, .accepted:
      .orange
    }
  }
}

struct WatchStatusRow: View {
  let status: WatchMonitorStatus

  var body: some View {
    Label {
      VStack(alignment: .leading, spacing: 2) {
        Text(status.title)
          .font(.headline)
        Text(status.subtitle)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    } icon: {
      Image(systemName: status.systemImage)
    }
  }
}

struct WatchAttentionRow: View {
  let item: MobileAttentionItem
  let submit: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Image(systemName: symbol)
          .foregroundStyle(color)
        Text(item.title)
          .font(.headline)
      }
      Text(item.subtitle)
        .font(.caption2)
        .foregroundStyle(.secondary)
      if item.commandKind != nil {
        Button(action: submit) {
          Label("Send", systemImage: "paperplane")
        }
      }
    }
  }

  private var symbol: String {
    switch item.kind {
    case .acpDecision: "lock.shield"
    case .pullRequest: "arrow.triangle.pull"
    case .taskBoard: "list.bullet.clipboard"
    case .blockedAgent: "person.fill.questionmark"
    case .commandFailure: "xmark.octagon"
    case .stationHealth: "desktopcomputer.trianglebadge.exclamationmark"
    }
  }

  private var color: Color {
    switch item.severity {
    case .critical: .red
    case .warning: .orange
    case .info: .secondary
    }
  }
}

#Preview {
  RootView()
    .environment(WatchMonitorStore(demoModeEnabled: true))
}
