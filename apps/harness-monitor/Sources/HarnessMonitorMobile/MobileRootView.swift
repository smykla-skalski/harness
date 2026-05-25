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
