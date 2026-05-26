import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto
import SwiftUI
import UIKit

struct MobileRootView: View {
  @Environment(MobileMonitorStore.self)
  private var store
  @Binding private var selectedTab: MobileRootTab

  init(selectedTab: Binding<MobileRootTab> = .constant(.today)) {
    _selectedTab = selectedTab
  }

  var body: some View {
    TabView(selection: $selectedTab) {
      Tab("Today", systemImage: "dot.radiowaves.left.and.right", value: MobileRootTab.today) {
        TodayView()
      }
      .badge(store.snapshot.needsYouCount)
      Tab("Sessions", systemImage: "rectangle.stack", value: MobileRootTab.sessions) {
        SessionsView()
      }
      Tab("Reviews", systemImage: "checklist", value: MobileRootTab.reviews) {
        ReviewsView()
      }
      Tab("Commands", systemImage: "terminal", value: MobileRootTab.commands) {
        CommandsView()
      }
      .badge(activeCommandCount)
      Tab("Settings", systemImage: "gearshape", value: MobileRootTab.settings) {
        SettingsView()
      }
    }
    .tabBarMinimizeBehavior(.onScrollDown)
    .task {
      await store.loadStoredPairings()
      await store.refresh()
    }
    .task {
      await store.runForegroundRefreshLoop()
    }
  }

  private var activeCommandCount: Int {
    store.commandsForSelectedStation.filter { !$0.status.isTerminal }.count
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
  @Environment(MobileMonitorStore.self)
  private var store

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
      .controlSize(.small)
    }
  }
}
