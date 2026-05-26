import HarnessMonitorCore
import SwiftUI
import UIKit

struct TodayView: View {
  @Environment(MobileMonitorStore.self)
  private var store
  @State private var pendingConfirmation: PendingCommandConfirmation?

  var body: some View {
    @Bindable var store = store
    NavigationStack {
      List {
        Section {
          SyncStatusRow(status: store.syncStatus)
        }
        Section {
          NeedsYouHeader(snapshot: store.snapshot)
        }
        Section("Needs You now") {
          if primaryAttention.isEmpty {
            ContentUnavailableView(
              "Nothing needs you",
              systemImage: "checkmark.circle",
              description: Text(
                "Live decisions, reviews, failures, and station health appear here.")
            )
          } else {
            ForEach(primaryAttention) { item in
              AttentionRow(item: item, onQueue: queue)
            }
          }
        }
        if !store.snapshot.stations.isEmpty {
          Section("Active Work") {
            if store.sessionsForSelectedStation.isEmpty && store.taskBoardForSelectedStation.isEmpty
            {
              ContentUnavailableView(
                "No active mirrored work",
                systemImage: "tray",
                description: Text("Live sessions and task-board items from this Mac appear here.")
              )
            } else {
              ForEach(store.sessionsForSelectedStation.prefix(3)) { session in
                NavigationLink {
                  SessionDetailView(sessionID: session.id)
                } label: {
                  CompactSessionRow(session: session)
                }
                .harnessBalancedListSeparator()
              }
              ForEach(store.taskBoardForSelectedStation.prefix(5)) { item in
                MobileTaskBoardRow(item: item)
              }
            }
          }
          Section("Stations") {
            ForEach(store.snapshot.stations) { station in
              StationHealthRow(station: station)
            }
          }
          if !secondaryAttention.isEmpty {
            Section("More Needs You") {
              ForEach(secondaryAttention) { item in
                AttentionRow(item: item, onQueue: queue)
              }
            }
          }
        }
      }
      .harnessMonitorListChrome()
      .navigationTitle("Today")
      .toolbar {
        Button {
          Task { await store.refresh() }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
      }
      .alert("Authentication failed", isPresented: $store.lastAuthenticationFailed) {
        Button("OK", role: .cancel) {}
      }
      .commandConfirmation($pendingConfirmation)
    }
  }

  private var primaryAttention: ArraySlice<MobileAttentionItem> {
    store.snapshot.sortedAttention.prefix(3)
  }

  private var secondaryAttention: ArraySlice<MobileAttentionItem> {
    store.snapshot.sortedAttention.dropFirst(3)
  }

  private func queue(_ item: MobileAttentionItem) {
    guard let kind = item.commandKind else {
      return
    }
    confirmCommandIfNeeded(kind: kind, message: item.confirmationMessage, pending: $pendingConfirmation) {
      Task { await store.queueCommand(from: item) }
    }
  }
}

struct CompactSessionRow: View {
  let session: MobileSessionSummary

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(
        systemName: session.blockedAgentCount > 0
          ? "person.crop.circle.badge.exclamationmark" : "rectangle.stack"
      )
      .foregroundStyle(session.blockedAgentCount > 0 ? .orange : .blue)
      .frame(width: 24)
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline) {
          Text(session.title)
            .font(.headline)
          Spacer(minLength: 8)
          Text(session.status)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        Text("\(session.projectName)  \(session.branch)")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text("\(session.activeAgentCount) active, \(session.blockedAgentCount) waiting")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 3)
    .harnessBalancedListSeparator()
  }
}

struct MobileTaskBoardRow: View {
  let item: MobileTaskBoardSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        HarnessCompactIconText(title: item.statusTitle, systemImage: iconName)
          .font(.caption.weight(.semibold))
          .foregroundStyle(statusColor)
        Spacer()
        Text(item.priorityTitle)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(priorityColor)
      }
      Text(item.title)
        .font(.headline)
        .lineLimit(2)
      if !item.bodyPreview.isEmpty {
        Text(item.bodyPreview)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(3)
      }
      if !item.tags.isEmpty {
        Text(item.tags.prefix(4).joined(separator: "  "))
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
    .harnessBalancedListSeparator()
  }

  var iconName: String {
    item.needsYou ? "exclamationmark.circle" : "list.bullet.clipboard"
  }

  var statusColor: Color {
    item.needsYou ? .orange : .blue
  }

  var priorityColor: Color {
    switch item.priority {
    case "critical": .red
    case "high": .orange
    default: .secondary
    }
  }
}

struct SyncStatusRow: View {
  @Environment(\.openURL)
  private var openURL
  let status: MobileMonitorSyncStatus

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: status.systemImage)
        .foregroundStyle(status.opensAppSettingsForRecovery ? .orange : .blue)
        .frame(width: 28)
      VStack(alignment: .leading, spacing: 3) {
        Text(status.title)
          .font(.headline)
        Text(status.subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
        if status.opensAppSettingsForRecovery {
          Button {
            guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else {
              return
            }
            openURL(settingsURL)
          } label: {
            Label("Open iOS Settings", systemImage: "gearshape")
          }
          .harnessActionButtonStyle(prominent: true)
          .padding(.top, 4)
        }
      }
      Spacer(minLength: 0)
    }
  }
}

struct NeedsYouHeader: View {
  let snapshot: MobileMirrorSnapshot

  var body: some View {
    HStack(alignment: .center, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Needs You")
          .font(.headline)
        Text("\(snapshot.needsYouCount) waiting across \(snapshot.stations.count) stations")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Text("\(snapshot.needsYouCount)")
        .font(.system(.largeTitle, design: .rounded, weight: .bold))
        .foregroundStyle(.red)
        .monospacedDigit()
    }
    .padding(.vertical, 6)
  }
}

struct AttentionRow: View {
  @Environment(MobileMonitorStore.self)
  private var store
  let item: MobileAttentionItem
  var onQueue: (MobileAttentionItem) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(alignment: .firstTextBaseline) {
        HarnessCompactIconText(title: item.kind.title, systemImage: iconName)
          .font(.caption)
          .foregroundStyle(severityColor)
        Spacer()
        Text(item.severity.title)
          .harnessStatusBadge(severityColor)
      }
      HStack(alignment: .top, spacing: 10) {
        VStack(alignment: .leading, spacing: 4) {
          Text(item.title)
            .font(.headline)
            .lineLimit(2)
          Text(item.subtitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        Spacer(minLength: 6)
        if item.commandKind != nil && store.canQueueCommand(stationID: item.stationID) {
          Button {
            onQueue(item)
          } label: {
            Label("Queue", systemImage: "checkmark.seal")
          }
          .harnessActionButtonStyle(prominent: item.severity == .critical, tint: severityColor)
        }
      }
    }
    .padding(.vertical, 3)
    .harnessBalancedListSeparator()
  }

  var iconName: String {
    switch item.kind {
    case .acpDecision: "lock.shield"
    case .pullRequest: "arrow.triangle.pull"
    case .taskBoard: "list.bullet.clipboard"
    case .blockedAgent: "person.crop.circle.badge.exclamationmark"
    case .commandFailure: "xmark.octagon"
    case .stationHealth: "desktopcomputer"
    }
  }

  var severityColor: Color {
    switch item.severity {
    case .critical: .red
    case .warning: .orange
    case .info: .blue
    }
  }
}

struct StationHealthRow: View {
  let station: MobileStationSummary

  var body: some View {
    HStack(spacing: 12) {
      Image(
        systemName: station.state == .online
          ? "checkmark.circle.fill" : "clock.badge.exclamationmark"
      )
      .foregroundStyle(station.state == .online ? .green : .orange)
      VStack(alignment: .leading) {
        Text(station.displayName)
          .font(.headline)
        Text("\(station.activeSessionCount) sessions, \(station.commandQueueCount) commands")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Text(station.state.title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }
    .harnessBalancedListSeparator()
  }
}
