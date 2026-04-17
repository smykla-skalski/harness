import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

@main
struct PreviewHostApp: App {
  init() {
    for _ in Self.forceLoadedSymbolReferences {}
  }

  var body: some Scene {
    WindowGroup("Harness Monitor Previews") {
      PreviewHostContentView()
        .frame(minWidth: 640, minHeight: 480)
    }
  }

  private static let forceLoadedSymbolReferences: [Any.Type] = [
    HarnessMonitorLaunchMode.self,
    PreviewFixtures.self,
  ]
}

private struct PreviewHostContentView: View {
  var body: some View {
    VStack(spacing: 16) {
      Text("Harness Monitor Previews")
        .font(.title2)
      Text("This host exists for SwiftUI Canvas previews.")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .padding(40)
  }
}
