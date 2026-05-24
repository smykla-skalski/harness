import HarnessMonitorCore
import SwiftUI
import WidgetKit

struct RootView: View {
  @Environment(WatchMonitorStore.self) private var store
  @State private var pendingAttention: MobileAttentionItem?

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
          ForEach(store.snapshot.commands.prefix(4)) { command in
            HStack {
              Image(systemName: command.status.isTerminal ? "checkmark.circle" : "clock")
              VStack(alignment: .leading) {
                Text(command.title)
                Text(command.status.title)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
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
