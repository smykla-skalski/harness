import AppKit
import HarnessMonitorKit
import SwiftUI

extension DashboardAgentsPreviewRenderer {
  @MainActor
  static func render(
    name: String,
    state: DashboardAgentBrowserViewState,
    textSizeIndex: Int,
    directory: String,
    selectedIdentity: DashboardAgentIdentity? = nil,
    selectionRawValue: String? = nil,
    decisions: [Decision] = [],
    bucketSession: SessionSummary? = nil,
    initialTerminalDetail: DashboardTerminalAgentDetail? = nil,
    initialAcpDetail: DashboardAcpAgentDetail? = nil,
    initialCodexDetail: DashboardCodexAgentDetail? = nil
  ) -> Bool {
    let size = NSSize(width: 1040, height: 700)
    let hosted = DashboardAgentsPreviewSurface(
      state: state,
      selectedIdentity: selectedIdentity,
      selectionRawValue: selectionRawValue,
      decisions: decisions,
      bucketSession: bucketSession,
      initialTerminalDetail: initialTerminalDetail,
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
    for _ in 0..<3 {
      view.layoutSubtreeIfNeeded()
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    }
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
}
