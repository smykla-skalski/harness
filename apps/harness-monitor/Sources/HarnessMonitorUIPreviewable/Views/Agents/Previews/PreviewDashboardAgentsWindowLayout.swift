import AppKit
import HarnessMonitorKit
import SwiftUI

@MainActor
private struct DashboardAgentsWindowLayoutPreview: View {
  let isolatesWholeDetailGeometry: Bool
  private let store: HarnessMonitorStore
  private let history: GlobalWindowNavigationHistory

  init(isolatesWholeDetailGeometry: Bool) {
    self.isolatesWholeDetailGeometry = isolatesWholeDetailGeometry
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .dashboardLoaded)
    store.connectionState = .offline("Daemon is not connected")
    store.supervisorOpenDecisions = Array(DashboardAgentsPreviewFixtures.previewDecisions.prefix(2))
    self.store = store
    history = GlobalWindowNavigationHistory(store: store, initialDashboardRoute: .agents)
  }

  var body: some View {
    DashboardWindowView(
      store: store,
      dashboardUI: store.contentUI.dashboard,
      sessionCatalog: store.sessionIndex.catalog,
      history: history,
      isolatesWholeDetailGeometry: isolatesWholeDetailGeometry
    )
  }
}

@MainActor
public enum DashboardAgentsWindowLayoutPreviewRenderer {
  public static func dump(
    toDirectory directory: String,
    isolatesWholeDetailGeometry: Bool
  ) -> Bool {
    let defaults = UserDefaults.standard
    let previousRoute = defaults.object(forKey: DashboardRouteRestorationDefaults.storageKey)
    defaults.set(
      DashboardWindowRoute.agents.rawValue,
      forKey: DashboardRouteRestorationDefaults.storageKey
    )
    defer {
      if let previousRoute {
        defaults.set(previousRoute, forKey: DashboardRouteRestorationDefaults.storageKey)
      } else {
        defaults.removeObject(forKey: DashboardRouteRestorationDefaults.storageKey)
      }
    }
    let name =
      isolatesWholeDetailGeometry
      ? "agents-window-before-whole-detail-geometry"
      : "agents-window-after-native-split-geometry"
    return render(
      name: name,
      isolatesWholeDetailGeometry: isolatesWholeDetailGeometry,
      directory: directory
    )
  }

  private static func render(
    name: String,
    isolatesWholeDetailGeometry: Bool,
    directory: String
  ) -> Bool {
    let size = NSSize(width: 1_120, height: 680)
    let hosted = DashboardAgentsWindowLayoutPreview(
      isolatesWholeDetailGeometry: isolatesWholeDetailGeometry
    )
    .harnessPreviewSceneAppearance(textSizeIndex: HarnessMonitorTextSize.defaultIndex)
    let hostingController = NSHostingController(rootView: hosted)
    let view = hostingController.view
    view.appearance = NSAppearance(named: .darkAqua)
    view.setFrameSize(size)
    let window = NSWindow(
      contentRect: view.bounds,
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false,
      screen: NSScreen.main
    )
    window.appearance = NSAppearance(named: .darkAqua)
    window.backgroundColor = .windowBackgroundColor
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.toolbarStyle = .unified
    window.contentViewController = hostingController
    guard let snapshotView = window.contentView?.superview else {
      return false
    }
    NSApplication.shared.setActivationPolicy(.regular)
    window.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
    window.orderFrontRegardless()
    window.makeMain()
    window.makeKey()
    window.layoutIfNeeded()
    for _ in 0..<12 {
      snapshotView.layoutSubtreeIfNeeded()
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    }
    snapshotView.layoutSubtreeIfNeeded()
    snapshotView.displayIfNeeded()
    let focusDeadline = Date().addingTimeInterval(3)
    while !NSApplication.shared.isActive || !window.isKeyWindow, Date() < focusDeadline {
      NSApplication.shared.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    guard NSApplication.shared.isActive, window.isKeyWindow else {
      FileHandle.standardError.write(Data("dashboard agents preview window is not focused\n".utf8))
      window.close()
      return false
    }
    snapshotView.layoutSubtreeIfNeeded()
    snapshotView.displayIfNeeded()
    defer { window.close() }

    return captureWindow(
      window,
      fallbackView: snapshotView,
      name: name,
      directory: directory
    )
  }

  private static func captureWindow(
    _ window: NSWindow,
    fallbackView: NSView,
    name: String,
    directory: String
  ) -> Bool {
    guard ProcessInfo.processInfo.environment["HARNESS_MONITOR_FOCUSED_PREVIEW_CAPTURE"] == "1"
    else {
      return captureView(fallbackView, name: name, directory: directory)
    }

    let request = URL(fileURLWithPath: directory)
      .appendingPathComponent(".capture-request-\(name)")
    let acknowledgement = URL(fileURLWithPath: directory)
      .appendingPathComponent(".capture-complete-\(name)")
    do {
      try Data("\(window.windowNumber)\n".utf8).write(to: request, options: .atomic)
    } catch {
      return false
    }

    let deadline = Date().addingTimeInterval(10)
    while !FileManager.default.fileExists(atPath: acknowledgement.path), Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    let destination = URL(fileURLWithPath: directory)
      .appendingPathComponent(name)
      .appendingPathExtension("png")
    guard
      FileManager.default.fileExists(atPath: acknowledgement.path),
      let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
      let size = attributes[.size] as? NSNumber
    else {
      return false
    }
    return size.intValue > 0
  }

  private static func captureView(
    _ view: NSView,
    name: String,
    directory: String
  ) -> Bool {
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      return false
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]), !data.isEmpty else {
      return false
    }
    do {
      try data.write(
        to: URL(fileURLWithPath: directory)
          .appendingPathComponent(name)
          .appendingPathExtension("png"),
        options: .atomic
      )
      return true
    } catch {
      return false
    }
  }
}
