import HarnessMonitorCore
import SwiftUI
import UIKit

struct MobileRootView: View {
  @Environment(MobileMonitorStore.self) private var store

  var body: some View {
    TabView {
      TodayView()
        .tabItem {
          Label("Today", systemImage: "dot.radiowaves.left.and.right")
        }
      SessionsView()
        .tabItem {
          Label("Sessions", systemImage: "rectangle.stack")
        }
      ReviewsView()
        .tabItem {
          Label("Reviews", systemImage: "checklist")
        }
      CommandsView()
        .tabItem {
          Label("Commands", systemImage: "terminal")
        }
      SettingsView()
        .tabItem {
          Label("Settings", systemImage: "gearshape")
        }
    }
    .task {
      await store.loadStoredPairings()
      await store.refresh()
    }
  }
}

struct StationPicker: View {
  @Environment(MobileMonitorStore.self) private var store

  var body: some View {
    @Bindable var store = store
    if store.snapshot.stations.isEmpty {
      Label("No paired Mac", systemImage: "link.badge.plus")
        .foregroundStyle(.secondary)
    } else {
      Picker("Station", selection: $store.selectedStationID) {
        ForEach(store.snapshot.stations) { station in
          Text(station.displayName).tag(station.id)
        }
      }
      .pickerStyle(.segmented)
    }
  }
}

struct TodayView: View {
  @Environment(MobileMonitorStore.self) private var store

  var body: some View {
    NavigationStack {
      List {
        Section {
          SyncStatusRow(status: store.syncStatus)
        }
        Section {
          NeedsYouHeader(snapshot: store.snapshot)
        }
        Section("Needs You now") {
          ForEach(store.snapshot.sortedAttention) { item in
            AttentionRow(item: item)
          }
        }
        Section("Stations") {
          ForEach(store.snapshot.stations) { station in
            StationHealthRow(station: station)
          }
        }
      }
      .navigationTitle("Today")
      .toolbar {
        Button {
          Task { await store.refresh() }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
      }
      .alert(
        "Authentication failed",
        isPresented: Binding(
          get: { store.lastAuthenticationFailed },
          set: { store.lastAuthenticationFailed = $0 }
        )
      ) {
        Button("OK", role: .cancel) {}
      }
    }
  }
}

struct SyncStatusRow: View {
  let status: MobileMonitorSyncStatus

  var body: some View {
    Label {
      VStack(alignment: .leading, spacing: 3) {
        Text(status.title)
          .font(.headline)
        Text(status.subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    } icon: {
      Image(systemName: status.systemImage)
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
  @Environment(MobileMonitorStore.self) private var store
  let item: MobileAttentionItem

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Label(item.kind.title, systemImage: iconName)
          .font(.caption)
          .foregroundStyle(severityColor)
        Spacer()
        Text(item.severity.title)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(severityColor)
      }
      Text(item.title)
        .font(.headline)
      Text(item.subtitle)
        .font(.subheadline)
        .foregroundStyle(.secondary)
      if item.commandKind != nil && store.canQueueCommands {
        Button {
          Task { await store.queueCommand(from: item) }
        } label: {
          Label("Queue Command", systemImage: "checkmark.seal")
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(.vertical, 4)
  }

  private var iconName: String {
    switch item.kind {
    case .acpDecision: "lock.shield"
    case .pullRequest: "arrow.triangle.pull"
    case .blockedAgent: "person.crop.circle.badge.exclamationmark"
    case .commandFailure: "xmark.octagon"
    case .stationHealth: "desktopcomputer"
    }
  }

  private var severityColor: Color {
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
  }
}

struct SessionsView: View {
  @Environment(MobileMonitorStore.self) private var store

  var body: some View {
    NavigationStack {
      List {
        Section {
          StationPicker()
        }
        Section("Sessions") {
          ForEach(store.sessionsForSelectedStation) { session in
            SessionRow(session: session)
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
      HStack {
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
      Text(session.summary)
        .font(.subheadline)
      HStack(spacing: 14) {
        Label("\(session.activeAgentCount)", systemImage: "person.2")
        Label("\(session.blockedAgentCount)", systemImage: "exclamationmark.triangle")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
  }
}

struct ReviewsView: View {
  @Environment(MobileMonitorStore.self) private var store

  var body: some View {
    NavigationStack {
      List {
        Section("Needs Me") {
          ForEach(store.reviewsNeedingMe) { review in
            ReviewRow(review: review)
          }
        }
        Section("Activity") {
          ForEach(store.snapshot.reviews.filter { !$0.needsYou }) { review in
            ReviewRow(review: review)
          }
        }
      }
      .navigationTitle("Reviews")
    }
  }
}

struct ReviewRow: View {
  let review: MobileReviewSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("#\(review.number)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Text(review.repository)
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        if review.needsYou {
          Image(systemName: "person.crop.circle.badge.checkmark")
            .foregroundStyle(.blue)
        }
      }
      Text(review.title)
        .font(.headline)
      Text("\(review.author)  \(review.state)  \(review.checksSummary)")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
  }
}

struct CommandsView: View {
  @Environment(MobileMonitorStore.self) private var store

  var body: some View {
    NavigationStack {
      List {
        Section {
          StationPicker()
        }
        Section("Queue") {
          ForEach(store.commandsForSelectedStation) { command in
            CommandRow(command: command)
          }
        }
      }
      .navigationTitle("Commands")
    }
  }
}

struct CommandRow: View {
  @Environment(MobileMonitorStore.self) private var store
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
            store.retry(command)
          } label: {
            Label("Retry", systemImage: "arrow.clockwise")
          }
          .buttonStyle(.bordered)
        }
        if !command.status.isTerminal {
          Button(role: .destructive) {
            store.cancel(command)
          } label: {
            Label("Cancel", systemImage: "xmark")
          }
          .buttonStyle(.bordered)
        }
      }
      .font(.caption)
    }
    .padding(.vertical, 4)
  }

  private var iconName: String {
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

  private var statusColor: Color {
    switch command.status {
    case .succeeded: .green
    case .failed, .expired, .cancelled: .red
    case .running: .blue
    case .draft, .queued, .accepted: .orange
    }
  }
}

struct SettingsView: View {
  @Environment(MobileMonitorStore.self) private var store
  @State private var scannerPresented = false

  var body: some View {
    @Bindable var store = store
    NavigationStack {
      List {
        Section("Pairing") {
          Button {
            scannerPresented = true
          } label: {
            Label("Scan Mac QR", systemImage: "qrcode.viewfinder")
          }
          ForEach(store.pairedCredentials) { credential in
            VStack(alignment: .leading) {
              Text(credential.stationName)
              Text(credential.stationPublicKeyFingerprint)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }
          }
        }
        Section("Notifications") {
          Toggle("Needs You", isOn: .constant(true))
          Toggle("Command failures", isOn: .constant(true))
          Toggle("Station health", isOn: .constant(true))
        }
        Section("Privacy") {
          Toggle(
            "Demo mode",
            isOn: Binding(
              get: { store.demoModeEnabled },
              set: { store.setDemoMode($0) }
            )
          )
          Label("Export mirrored records", systemImage: "square.and.arrow.up")
          Label("Delete CloudKit mirror", systemImage: "trash")
            .foregroundStyle(.red)
        }
      }
      .navigationTitle("Settings")
      .sheet(isPresented: $scannerPresented) {
        MobilePairingScannerView { url in
          scannerPresented = false
          Task {
            await store.handleOpenURL(url, deviceName: UIDevice.current.name)
          }
        }
      }
    }
  }
}
