import AppKit
import HarnessMonitorKit
import SwiftUI

public enum DashboardAgentsPreviewRenderer {
  @MainActor
  public static func dump(toDirectory directory: String) -> Bool {
    do {
      try FileManager.default.createDirectory(
        atPath: directory,
        withIntermediateDirectories: true
      )
    } catch {
      return false
    }

    let defaultIndex = HarnessMonitorTextSize.defaultIndex
    let largestIndex = HarnessMonitorTextSize.scales.count - 1
    return render(
      name: "agents-live",
      state: DashboardAgentsPreviewFixtures.liveState,
      textSizeIndex: defaultIndex,
      directory: directory
    )
      && render(
        name: "agents-first-run",
        state: DashboardAgentsPreviewFixtures.firstRunState,
        textSizeIndex: defaultIndex,
        directory: directory
      )
      && render(
        name: "agents-live-largest-text",
        state: DashboardAgentsPreviewFixtures.liveState,
        textSizeIndex: largestIndex,
        directory: directory
      )
      && render(
        name: "agents-loading",
        state: DashboardAgentsPreviewFixtures.loadingState,
        textSizeIndex: defaultIndex,
        directory: directory
      )
      && render(
        name: "agents-empty",
        state: DashboardAgentsPreviewFixtures.emptyState,
        textSizeIndex: defaultIndex,
        directory: directory
      )
      && render(
        name: "agents-stale-cache",
        state: DashboardAgentsPreviewFixtures.cachedState,
        textSizeIndex: defaultIndex,
        directory: directory
      )
      && render(
        name: "agents-offline",
        state: DashboardAgentsPreviewFixtures.offlineState,
        textSizeIndex: defaultIndex,
        directory: directory
      )
      && render(
        name: "agents-request-failure",
        state: DashboardAgentsPreviewFixtures.failureState,
        textSizeIndex: defaultIndex,
        directory: directory
      )
      && renderAcpStates(
        defaultIndex: defaultIndex,
        largestIndex: largestIndex,
        directory: directory
      )
      && renderCodexStates(
        defaultIndex: defaultIndex,
        largestIndex: largestIndex,
        directory: directory
      )
  }

  @MainActor
  private static func renderAcpStates(
    defaultIndex: Int,
    largestIndex: Int,
    directory: String
  ) -> Bool {
    render(
      name: "agents-acp-management",
      state: DashboardAgentsPreviewFixtures.liveState,
      textSizeIndex: defaultIndex,
      directory: directory,
      selectedIdentity: DashboardAgentsPreviewFixtures.acpAgent.identity,
      initialAcpDetail: DashboardAgentsPreviewFixtures.managedAcpDetail
    )
      && render(
        name: "agents-acp-largest-text",
        state: DashboardAgentsPreviewFixtures.liveState,
        textSizeIndex: largestIndex,
        directory: directory,
        selectedIdentity: DashboardAgentsPreviewFixtures.acpAgent.identity,
        initialAcpDetail: DashboardAgentsPreviewFixtures.managedAcpDetail
      )
      && render(
        name: "agents-acp-unavailable",
        state: DashboardAgentsPreviewFixtures.liveState,
        textSizeIndex: defaultIndex,
        directory: directory,
        selectedIdentity: DashboardAgentsPreviewFixtures.acpAgent.identity,
        initialAcpDetail: DashboardAgentsPreviewFixtures.unavailableAcpDetail
      )
      && render(
        name: "agents-acp-stopped",
        state: DashboardAgentsPreviewFixtures.stoppedAcpState,
        textSizeIndex: defaultIndex,
        directory: directory,
        selectedIdentity: DashboardAgentsPreviewFixtures.stoppedAcpAgent.identity,
        initialAcpDetail: DashboardAgentsPreviewFixtures.stoppedAcpDetail
      )
      && renderAcpCreateSheet(textSizeIndex: defaultIndex, directory: directory)
  }

  @MainActor
  private static func renderCodexStates(
    defaultIndex: Int,
    largestIndex: Int,
    directory: String
  ) -> Bool {
    render(
      name: "agents-codex-management",
      state: DashboardAgentsPreviewFixtures.liveState,
      textSizeIndex: defaultIndex,
      directory: directory,
      selectedIdentity: DashboardAgentsPreviewFixtures.codexAgent.identity,
      initialCodexDetail: DashboardAgentsPreviewFixtures.managedCodexDetail
    )
      && render(
        name: "agents-codex-largest-text",
        state: DashboardAgentsPreviewFixtures.liveState,
        textSizeIndex: largestIndex,
        directory: directory,
        selectedIdentity: DashboardAgentsPreviewFixtures.codexAgent.identity,
        initialCodexDetail: DashboardAgentsPreviewFixtures.managedCodexDetail
      )
      && render(
        name: "agents-codex-unavailable",
        state: DashboardAgentsPreviewFixtures.liveState,
        textSizeIndex: defaultIndex,
        directory: directory,
        selectedIdentity: DashboardAgentsPreviewFixtures.codexAgent.identity,
        initialCodexDetail: DashboardAgentsPreviewFixtures.unavailableCodexDetail
      )
      && render(
        name: "agents-codex-stopped",
        state: DashboardAgentsPreviewFixtures.stoppedCodexState,
        textSizeIndex: defaultIndex,
        directory: directory,
        selectedIdentity: DashboardAgentsPreviewFixtures.stoppedCodexAgent.identity,
        initialCodexDetail: DashboardAgentsPreviewFixtures.stoppedCodexDetail
      )
      && render(
        name: "agents-codex-failed",
        state: DashboardAgentsPreviewFixtures.failedCodexState,
        textSizeIndex: defaultIndex,
        directory: directory,
        selectedIdentity: DashboardAgentsPreviewFixtures.failedCodexAgent.identity,
        initialCodexDetail: DashboardAgentsPreviewFixtures.failedCodexDetail
      )
      && renderCodexCreateSheet(textSizeIndex: defaultIndex, directory: directory)
  }

  @MainActor
  private static func render(
    name: String,
    state: DashboardAgentBrowserViewState,
    textSizeIndex: Int,
    directory: String,
    selectedIdentity: DashboardAgentIdentity? = nil,
    initialAcpDetail: DashboardAcpAgentDetail? = nil,
    initialCodexDetail: DashboardCodexAgentDetail? = nil
  ) -> Bool {
    let size = NSSize(width: 1040, height: 700)
    let hosted = DashboardAgentsPreviewSurface(
      state: state,
      selectedIdentity: selectedIdentity,
      initialAcpDetail: initialAcpDetail,
      initialCodexDetail: initialCodexDetail
    )
    .frame(width: size.width, height: size.height)
    .background(Color(nsColor: .windowBackgroundColor))
    .harnessPreviewSceneAppearance(textSizeIndex: textSizeIndex)
    let view = NSHostingView(rootView: hosted)
    view.appearance = NSAppearance(named: .darkAqua)
    view.setFrameSize(size)
    let window = NSWindow(
      contentRect: view.bounds,
      styleMask: .borderless,
      backing: .buffered,
      defer: false,
      screen: NSScreen.main
    )
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    view.layoutSubtreeIfNeeded()

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

  @MainActor
  private static func renderAcpCreateSheet(textSizeIndex: Int, directory: String) -> Bool {
    let size = NSSize(width: 1040, height: 700)
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .dashboardLoaded)
    let hosted = ZStack {
      Color(nsColor: .windowBackgroundColor)
      DashboardAcpAgentCreateSheet(
        store: store,
        sessions: [PreviewFixtures.summary],
        initialDescriptors: [DashboardAgentsPreviewFixtures.acpDescriptor],
        initialProbes: [DashboardAgentsPreviewFixtures.acpProbe],
        onCreated: { _, _ in }
      )
      .frame(width: 680, height: 640)
      .background(.background, in: RoundedRectangle(cornerRadius: 14))
      .shadow(radius: 20)
    }
    .frame(width: size.width, height: size.height)
    .harnessPreviewSceneAppearance(textSizeIndex: textSizeIndex)
    let view = NSHostingView(rootView: hosted)
    view.appearance = NSAppearance(named: .darkAqua)
    view.setFrameSize(size)
    view.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]), !data.isEmpty else {
      return false
    }
    do {
      try data.write(
        to: URL(fileURLWithPath: directory).appendingPathComponent("agents-acp-create.png"),
        options: .atomic
      )
      return true
    } catch {
      return false
    }
  }

  @MainActor
  private static func renderCodexCreateSheet(textSizeIndex: Int, directory: String) -> Bool {
    renderSheet(
      name: "agents-codex-create",
      textSizeIndex: textSizeIndex,
      directory: directory
    ) {
      DashboardCodexAgentCreateSheet(
        store: HarnessMonitorPreviewStoreFactory.makeStore(for: .dashboardLoaded),
        sessions: [PreviewFixtures.summary],
        initialCatalogs: [DashboardAgentsPreviewFixtures.codexCatalog],
        onCreated: { _, _ in }
      )
      .frame(width: 680, height: 660)
    }
  }

  @MainActor
  private static func renderSheet<Content: View>(
    name: String,
    textSizeIndex: Int,
    directory: String,
    @ViewBuilder content: () -> Content
  ) -> Bool {
    let size = NSSize(width: 1040, height: 700)
    let hosted = ZStack {
      Color(nsColor: .windowBackgroundColor)
      content()
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 20)
    }
    .frame(width: size.width, height: size.height)
    .harnessPreviewSceneAppearance(textSizeIndex: textSizeIndex)
    let view = NSHostingView(rootView: hosted)
    view.appearance = NSAppearance(named: .darkAqua)
    view.setFrameSize(size)
    view.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]), !data.isEmpty else {
      return false
    }
    do {
      try data.write(
        to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"),
        options: .atomic
      )
      return true
    } catch {
      return false
    }
  }
}

struct DashboardAgentsPreviewSurface: View {
  let state: DashboardAgentBrowserViewState
  let initialAcpDetail: DashboardAcpAgentDetail?
  let initialCodexDetail: DashboardCodexAgentDetail?
  private let store: HarnessMonitorStore
  private let history: GlobalWindowNavigationHistory
  private let selectionDefaults: UserDefaults

  @MainActor
  init(
    state: DashboardAgentBrowserViewState,
    selectedIdentity: DashboardAgentIdentity? = nil,
    initialAcpDetail: DashboardAcpAgentDetail? = nil,
    initialCodexDetail: DashboardCodexAgentDetail? = nil
  ) {
    self.state = state
    self.initialAcpDetail = initialAcpDetail
    self.initialCodexDetail = initialCodexDetail
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .dashboardLoaded)
    self.store = store
    history = GlobalWindowNavigationHistory(store: store, initialDashboardRoute: .agents)
    let suiteName = "HarnessMonitorPreview.DashboardAgents.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    defaults.set(
      selectedIdentity?.selectionRawValue ?? state.agents.first?.identity.selectionRawValue ?? "",
      forKey: DashboardAgentSelectionDefaults.storageKey
    )
    selectionDefaults = defaults
  }

  var body: some View {
    DashboardAgentsRouteView(
      store: store,
      sessions: [PreviewFixtures.summary],
      history: history,
      isRouteVisible: true,
      refreshesAutomatically: false,
      initialState: state,
      initialAcpDetail: initialAcpDetail,
      initialCodexDetail: initialCodexDetail,
      selectionDefaults: selectionDefaults
    )
  }
}
