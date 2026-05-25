import AppKit
import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

@main
struct PreviewHostApp: App {
  init() {
    // Headless render mode: dump the diff fixtures to PNGs and exit before any
    // window or dock presence appears, so verification never steals focus.
    if let dumpDirectory = ProcessInfo.processInfo.environment["HARNESS_DIFF_LAB_DUMP"] {
      NSApplication.shared.setActivationPolicy(.prohibited)
      DashboardReviewFileDiffLabRenderer.dumpFixtures(toDirectory: dumpDirectory)
      exit(0)
    }
    for _ in Self.forceLoadedSymbolReferences {}
  }

  var body: some Scene {
    WindowGroup("Harness Monitor Previews") {
      PreviewHostContentView()
        .frame(minWidth: 900, minHeight: 600)
    }
  }

  private static let forceLoadedSymbolReferences: [Any.Type] = [
    HarnessMonitorLaunchMode.self,
    PreviewFixtures.self,
  ]
}

private struct PreviewHostContentView: View {
  var body: some View {
    DashboardReviewFileDiffLab()
  }
}
