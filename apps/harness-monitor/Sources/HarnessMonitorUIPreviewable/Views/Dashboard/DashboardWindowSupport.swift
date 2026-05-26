import Foundation
import HarnessMonitorKit
import SwiftUI

private struct DashboardBannerStackModel: Equatable {
  let showsContentChrome: Bool
  let observedDaemonWireVersion: Int?

  init(
    contentChrome: ContentChromeBannerModel,
    observedDaemonWireVersion: Int?
  ) {
    showsContentChrome = contentChrome.isPresented
    self.observedDaemonWireVersion = observedDaemonWireVersion
  }

  var showsDaemonWireVersionSkew: Bool {
    guard let observedDaemonWireVersion else { return false }
    return observedDaemonWireVersion < HarnessMonitorStore.minimumDaemonWireVersion
  }

  var isPresented: Bool {
    showsContentChrome || showsDaemonWireVersionSkew
  }
}

struct DashboardBannerStack<Content: View>: View {
  let store: HarnessMonitorStore
  private let content: Content

  init(store: HarnessMonitorStore, @ViewBuilder content: () -> Content) {
    self.store = store
    self.content = content()
  }

  private var chrome: HarnessMonitorStore.ContentChromeSlice {
    store.contentUI.chrome
  }

  private var chromeBannerModel: ContentChromeBannerModel {
    ContentChromeBannerModel(
      persistenceError: chrome.persistenceError,
      sessionDataAvailability: chrome.sessionDataAvailability,
      mcpStatus: chrome.mcpStatus,
      hasACPBridgeBanner: chrome.acpBridgeBanner != nil
    )
  }

  private var model: DashboardBannerStackModel {
    DashboardBannerStackModel(
      contentChrome: chromeBannerModel,
      observedDaemonWireVersion: store.health?.wireVersion
    )
  }

  var body: some View {
    WindowBannerChrome(
      windowID: HarnessMonitorWindowID.dashboard,
      isPresented: model.isPresented
    ) {
      content
    } banners: {
      topChrome
    }
  }

  @ViewBuilder private var topChrome: some View {
    VStack(spacing: 0) {
      if let observed = model.observedDaemonWireVersion, model.showsDaemonWireVersionSkew {
        DaemonWireVersionSkewBanner(
          observed: observed,
          expected: HarnessMonitorStore.minimumDaemonWireVersion
        )
        chromeDivider(tint: HarnessMonitorTheme.danger)
      }
      ContentChromeBannerStack(
        store: store,
        contentChrome: chrome,
        windowID: HarnessMonitorWindowID.dashboard
      )
    }
  }

  private func chromeDivider(tint: Color) -> some View {
    WindowBannerDivider(tint: tint)
  }
}

struct DashboardPerfRouteHook: ViewModifier {
  let selectedRouteBinding: Binding<DashboardWindowRoute>
  private let isActive = HarnessMonitorPerfDashboardRouteBus.isActive()

  func body(content: Content) -> some View {
    if isActive {
      content
        .onReceive(
          NotificationCenter.default.publisher(
            for: HarnessMonitorPerfDashboardRouteBus.routeChange
          )
        ) { note in
          guard
            let raw = note.userInfo?[HarnessMonitorPerfDashboardRouteBus.routeRawKey] as? String,
            let next = DashboardWindowRoute(rawValue: raw)
          else { return }
          guard selectedRouteBinding.wrappedValue != next else { return }
          withAnimation(.easeInOut(duration: 0.15)) {
            selectedRouteBinding.wrappedValue = next
          }
          HarnessMonitorPerfDashboardRouteBus.recordAccepted(raw: raw)
        }
    } else {
      content
    }
  }
}

public enum DashboardWindowRoute: String, CaseIterable, Identifiable, Sendable {
  case taskBoard
  case policyCanvas
  case notifications
  case diagnostics
  case reviews
  case debugging

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .taskBoard:
      "Board"
    case .policyCanvas:
      "Policy"
    case .notifications:
      "Notifications"
    case .diagnostics:
      "Diagnostics"
    case .reviews:
      "Reviews"
    case .debugging:
      "Debugging"
    }
  }

  public var systemImage: String {
    switch self {
    case .taskBoard:
      "square.grid.2x2"
    case .policyCanvas:
      "point.3.connected.trianglepath.dotted"
    case .notifications:
      "bell.badge"
    case .diagnostics:
      "stethoscope"
    case .reviews:
      "shippingbox.circle"
    case .debugging:
      "wrench.and.screwdriver"
    }
  }

}

public enum DashboardRouteRestorationDefaults {
  public static let storageKey = "dashboard.route"
  public static let defaultRoute = DashboardWindowRoute.taskBoard
  public static var defaultRawValue: String { defaultRoute.rawValue }

  public static func initialRoute(
    userDefaults: UserDefaults = .standard
  ) -> DashboardWindowRoute {
    guard
      let rawValue = userDefaults.string(forKey: storageKey),
      let route = DashboardWindowRoute(rawValue: rawValue)
    else {
      return defaultRoute
    }
    return route
  }
}

enum DashboardSidebarSelection: Hashable {
  case route(DashboardWindowRoute)
  case session(String)
}

struct DashboardSidebar: View {
  let store: HarnessMonitorStore
  @Binding var selectedRoute: DashboardWindowRoute
  let recentSessions: [SessionSummary]
  let statusModel: SessionStatusSummaryModel
  @State private var dashboardSelection: DashboardSidebarSelection?
  @State private var pendingSessionOpenID: String?
  @Environment(\.openWindow)
  private var openWindow
  @Environment(\.harnessTextSizeIndex)
  private var textSizeIndex

  private var dashboardSelectionBinding: Binding<DashboardSidebarSelection?> {
    Binding(
      get: { dashboardSelection ?? .route(selectedRoute) },
      set: { newValue in
        guard let newValue else { return }
        dashboardSelection = newValue
        switch newValue {
        case .route(let route):
          selectedRoute = route
        case .session(let sessionID):
          guard shouldOpenSessionWindow(for: NSApp.currentEvent) else {
            return
          }
          pendingSessionOpenID = sessionID
        }
      }
    )
  }

  private func shouldOpenSessionWindow(for event: NSEvent?) -> Bool {
    guard let event else {
      return true
    }
    switch event.type {
    case .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
      return false
    case .leftMouseDown, .leftMouseUp:
      return !event.modifierFlags.contains(.control)
    default:
      return true
    }
  }

  var body: some View {
    ViewBodySignposter.trace(
      Self.self,
      "DashboardSidebar",
      attributes: [
        "harness.view.selected_route": selectedRoute.rawValue,
        "harness.view.route_count": String(DashboardWindowRoute.allCases.count),
      ]
    ) {
      HarnessMonitorSidebar(
        accessibilityIdentifier: HarnessMonitorAccessibility.dashboardSidebar,
        statusModel: statusModel
      ) {
        List(selection: dashboardSelectionBinding) {
          Section {
            ForEach(DashboardWindowRoute.allCases, id: \.id) { route in
              let isSelected = selectedRoute == route
              SessionSidebarRow(
                title: route.title,
                systemImage: route.systemImage
              )
              .tag(DashboardSidebarSelection.route(route))
              .accessibilityIdentifier(
                HarnessMonitorAccessibility.dashboardWindowRoute(route.rawValue)
              )
              .accessibilityValue(isSelected ? "selected" : "not selected")
            }
          }
          DashboardSidebarRecentSessionsSection(store: store, sessions: recentSessions)
        }
        .harnessMonitorSidebarListChrome(
          rowSize: harnessSidebarRowSize(for: textSizeIndex)
        )
        .onAppear {
          dashboardSelection = .route(selectedRoute)
        }
        .onChange(of: selectedRoute) { _, route in
          dashboardSelection = .route(route)
        }
        .onChange(of: pendingSessionOpenID) { _, sessionID in
          guard let sessionID else {
            return
          }
          openWindow.openHarnessSessionWindow(sessionID: sessionID)
          pendingSessionOpenID = nil
          dashboardSelection = .route(selectedRoute)
        }
      }
    }
  }
}
