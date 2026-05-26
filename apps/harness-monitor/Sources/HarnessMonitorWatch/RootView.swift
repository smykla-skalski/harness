import HarnessMonitorCore
import SwiftUI
import WidgetKit

struct RootView: View {
  @Environment(WatchMonitorStore.self)
  private var store
  @State private var pendingAttention: MobileAttentionItem?
  @State private var pendingCancellation: MobileCommandRecord?
  @State private var pendingRetry: MobileCommandRecord?
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
              WatchAttentionRow(
                item: item,
                canSubmit: store.canQueueCommand(stationID: item.stationID)
              ) {
                pendingAttention = item
              }
            }
          }
        }
        Section("Live Work") {
          if store.sessionsForSelectedStation.isEmpty && store.taskBoardForSelectedStation.isEmpty {
            Label("No active work", systemImage: "tray")
          } else {
            ForEach(store.sessionsForSelectedStation.prefix(3)) { session in
              WatchSessionRow(session: session)
            }
            ForEach(store.taskBoardForSelectedStation.prefix(4)) { item in
              WatchTaskBoardRow(item: item)
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
            WatchCommandRow(
              command: command,
              retry: {
                pendingRetry = command
              },
              cancel: {
                pendingCancellation = command
              }
            )
          }
        }
      }
      .navigationTitle("Harness")
      .sensoryFeedback(trigger: store.status) { _, status in
        switch status {
        case .commandQueued:
          .success
        case .commandFailed:
          .error
        case .commandCancelled:
          .warning
        default:
          nil
        }
      }
      .refreshable {
        await store.refresh()
      }
      .task {
        WidgetCenter.shared.reloadAllTimelines()
        await store.load()
      }
      .task {
        await store.runForegroundRefreshLoop()
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
      } message: {
        Text(pendingAttention?.confirmationMessage ?? "")
      }
      .confirmationDialog(
        "Retry Command",
        isPresented: Binding(
          get: { pendingRetry != nil },
          set: { if !$0 { pendingRetry = nil } }
        ),
        titleVisibility: .visible
      ) {
        Button("Retry") {
          guard let pendingRetry else {
            return
          }
          Task {
            await store.retry(pendingRetry)
            self.pendingRetry = nil
          }
        }
        Button("Cancel", role: .cancel) {
          pendingRetry = nil
        }
      } message: {
        Text(pendingRetry?.confirmationText ?? "")
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

struct WatchSessionRow: View {
  let session: MobileSessionSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label(
        session.title,
        systemImage: session.blockedAgentCount > 0 ? "person.fill.questionmark" : "rectangle.stack"
      )
      .font(.headline)
      Text("\(session.activeAgentCount) active, \(session.blockedAgentCount) waiting")
        .font(.caption2)
        .foregroundStyle(.secondary)
      Text(session.lastActivityAt, style: .relative)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }
}

struct WatchTaskBoardRow: View {
  let item: MobileTaskBoardSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label(
        item.title,
        systemImage: item.needsYou ? "exclamationmark.circle" : "list.bullet.clipboard"
      )
      .font(.headline)
      .foregroundStyle(item.needsYou ? .orange : .primary)
      Text("\(item.statusTitle) - \(item.priorityTitle)")
        .font(.caption2)
        .foregroundStyle(.secondary)
      if !item.bodyPreview.isEmpty {
        Text(item.bodyPreview)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

struct WatchCommandRow: View {
  let command: MobileCommandRecord
  let retry: () -> Void
  let cancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: symbol)
            .foregroundStyle(color)
            .accessibilityHidden(true)
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
      }
      .accessibilityElement(children: .combine)
      if command.canRetrySafely {
        Button(action: retry) {
          Label("Retry", systemImage: "arrow.clockwise")
        }
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
    .accessibilityElement(children: .combine)
  }
}

struct WatchAttentionRow: View {
  let item: MobileAttentionItem
  let canSubmit: Bool
  let submit: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Image(systemName: symbol)
            .foregroundStyle(color)
            .accessibilityHidden(true)
          Text(item.title)
            .font(.headline)
        }
        Text(item.subtitle)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .combine)
      if item.commandKind != nil && canSubmit {
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
