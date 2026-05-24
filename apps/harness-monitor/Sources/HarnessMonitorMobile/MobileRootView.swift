import HarnessMonitorCore
import HarnessMonitorCrypto
import SwiftUI
import UIKit

struct MobileRootView: View {
  @Environment(MobileMonitorStore.self) private var store
  @Binding private var selectedTab: MobileRootTab

  init(selectedTab: Binding<MobileRootTab> = .constant(.today)) {
    _selectedTab = selectedTab
  }

  var body: some View {
    TabView(selection: $selectedTab) {
      TodayView()
        .tabItem {
          Label("Today", systemImage: "dot.radiowaves.left.and.right")
        }
        .tag(MobileRootTab.today)
      SessionsView()
        .tabItem {
          Label("Sessions", systemImage: "rectangle.stack")
        }
        .tag(MobileRootTab.sessions)
      ReviewsView()
        .tabItem {
          Label("Reviews", systemImage: "checklist")
        }
        .tag(MobileRootTab.reviews)
      CommandsView()
        .tabItem {
          Label("Commands", systemImage: "terminal")
        }
        .tag(MobileRootTab.commands)
      SettingsView()
        .tabItem {
          Label("Settings", systemImage: "gearshape")
        }
        .tag(MobileRootTab.settings)
    }
    .task {
      await store.loadStoredPairings()
      await store.refresh()
    }
  }
}

enum MobileRootTab: Hashable {
  case today
  case sessions
  case reviews
  case commands
  case settings

  init?(url: URL) {
    guard url.scheme == MobilePairingInvitationCodec.urlScheme else {
      return nil
    }
    switch url.host?.lowercased() {
    case "today", "taskboard":
      self = .today
    case "sessions":
      self = .sessions
    case "reviews":
      self = .reviews
    case "commands":
      self = .commands
    case "settings":
      self = .settings
    default:
      return nil
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
          if store.snapshot.sortedAttention.isEmpty {
            ContentUnavailableView(
              "Nothing needs you",
              systemImage: "checkmark.circle",
              description: Text(
                "Live decisions, reviews, failures, and station health appear here.")
            )
          } else {
            ForEach(store.snapshot.sortedAttention) { item in
              AttentionRow(item: item)
            }
          }
        }
        Section("Active Work") {
          if store.sessionsForSelectedStation.isEmpty && store.taskBoardForSelectedStation.isEmpty {
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

struct CompactSessionRow: View {
  let session: MobileSessionSummary

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: session.blockedAgentCount > 0 ? "person.crop.circle.badge.exclamationmark" : "rectangle.stack")
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
  }
}

struct MobileTaskBoardRow: View {
  let item: MobileTaskBoardSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Label(item.statusTitle, systemImage: iconName)
          .font(.caption.weight(.semibold))
          .foregroundStyle(statusColor)
        Spacer()
        Text(item.priorityTitle)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(priorityColor)
      }
      Text(item.title)
        .font(.headline)
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
  }

  private var iconName: String {
    item.needsYou ? "exclamationmark.circle" : "list.bullet.clipboard"
  }

  private var statusColor: Color {
    item.needsYou ? .orange : .blue
  }

  private var priorityColor: Color {
    switch item.priority {
    case "critical": .red
    case "high": .orange
    default: .secondary
    }
  }
}

struct SyncStatusRow: View {
  @Environment(\.openURL) private var openURL
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
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
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
    case .taskBoard: "list.bullet.clipboard"
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

struct CommandsView: View {
  @Environment(MobileMonitorStore.self) private var store
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
        if command.status == .queued {
          Button(role: .destructive) {
            Task { await store.cancel(command) }
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
  @State private var deleteMirrorConfirmationPresented = false
  @State private var pendingUnpairCredential: MobilePairedStationCredential?
  @State private var mirrorExportFile: MobileMirrorExportFile?

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
          if store.syncStatus.opensAppSettingsForRecovery {
            SyncStatusRow(status: store.syncStatus)
          }
          ForEach(store.pairedCredentials) { credential in
            HStack(alignment: .top, spacing: 12) {
              VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                  Text(credential.stationName)
                  if credential.defaultStation {
                    Text("Default")
                      .font(.caption2.weight(.semibold))
                      .padding(.horizontal, 6)
                      .padding(.vertical, 2)
                      .background(.blue.opacity(0.14), in: Capsule())
                      .foregroundStyle(.blue)
                  }
                }
                Text(credential.stationPublicKeyFingerprint)
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
                Text(credential.pairedAt.formatted(date: .abbreviated, time: .shortened))
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
              Spacer(minLength: 8)
              Button(role: .destructive) {
                pendingUnpairCredential = credential
              } label: {
                Label("Unpair", systemImage: "xmark.circle")
              }
              .buttonStyle(.borderless)
            }
          }
        }
        Section("Notifications") {
          ForEach(MobileNotificationCategory.allCases) { category in
            Toggle(
              isOn: Binding(
                get: { store.notificationSettings.isEnabled(category) },
                set: { store.setNotificationCategory(category, enabled: $0) }
              )
            ) {
              VStack(alignment: .leading, spacing: 2) {
                Text(category.title)
                Text(category.subtitle)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
          Button {
            Task {
              await store.requestNotificationAuthorization()
            }
          } label: {
            Label("Enable Notifications", systemImage: "bell.badge")
          }
        }
        Section("Privacy") {
          Toggle(
            "Demo mode",
            isOn: Binding(
              get: { store.demoModeEnabled },
              set: { store.setDemoMode($0) }
            )
          )
          Button {
            Task {
              guard let url = await store.exportMirroredRecords() else {
                return
              }
              mirrorExportFile = MobileMirrorExportFile(url: url)
            }
          } label: {
            Label("Export all mirrored records", systemImage: "square.and.arrow.up")
          }
          Button(role: .destructive) {
            deleteMirrorConfirmationPresented = true
          } label: {
            Label("Delete CloudKit mirrors", systemImage: "trash")
          }
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
      .sheet(item: $mirrorExportFile) { exportFile in
        NavigationStack {
          ShareLink(item: exportFile.url) {
            Label("Share mirror export", systemImage: "square.and.arrow.up")
          }
          .navigationTitle("Mirror Export")
          .toolbar {
            Button("Done") {
              mirrorExportFile = nil
            }
          }
        }
        .presentationDetents([.medium])
      }
      .confirmationDialog(
        "Delete CloudKit mirrors?",
        isPresented: $deleteMirrorConfirmationPresented,
        titleVisibility: .visible
      ) {
        Button("Delete Mirrors", role: .destructive) {
          Task {
            await store.deleteCloudKitMirror()
          }
        }
      }
      .confirmationDialog(
        "Unpair Mac?",
        isPresented: Binding(
          get: { pendingUnpairCredential != nil },
          set: { if !$0 { pendingUnpairCredential = nil } }
        ),
        titleVisibility: .visible,
        presenting: pendingUnpairCredential
      ) { credential in
        Button("Unpair \(credential.stationName)", role: .destructive) {
          Task {
            await store.unpair(stationID: credential.stationID)
            pendingUnpairCredential = nil
          }
        }
      } message: { credential in
        Text(
          "This removes the local pairing credential and syncs the updated trusted-device set to Apple Watch."
        )
      }
    }
  }
}

struct MobileMirrorExportFile: Identifiable {
  let url: URL

  var id: String {
    url.absoluteString
  }
}
