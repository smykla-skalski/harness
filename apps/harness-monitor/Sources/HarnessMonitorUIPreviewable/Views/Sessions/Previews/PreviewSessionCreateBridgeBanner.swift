import HarnessMonitorKit
import SwiftUI

#Preview("Session Create Host Bridge Banner") {
  SessionCreateBridgeBannerPreviewSurface(
    textSizeIndex: HarnessMonitorTextSize.defaultIndex
  )
}

@MainActor
private struct SessionCreateBridgeBannerPreviewSurface: View {
  let textSizeIndex: Int
  @State private var store: HarnessMonitorStore
  private let environment: HarnessMonitorEnvironment

  init(textSizeIndex: Int) {
    self.textSizeIndex = textSizeIndex
    let homeDirectory = URL(fileURLWithPath: "/Users/monitor", isDirectory: true)
    let lane = "discovered-daemon"
    let dataHomeRoot =
      homeDirectory
      .appendingPathComponent("Library/Group Containers", isDirectory: true)
      .appendingPathComponent(HarnessMonitorAppGroup.identifier, isDirectory: true)
      .appendingPathComponent("runtime-lanes", isDirectory: true)
      .appendingPathComponent(lane, isDirectory: true)
    let environment = HarnessMonitorEnvironment(
      values: [
        HarnessMonitorRuntimeLane.environmentKey: lane,
        HarnessMonitorAppGroup.daemonDataHomeEnvironmentKey: dataHomeRoot.path,
      ],
      homeDirectory: homeDirectory,
      bundleURL: nil
    )
    self.environment = environment
    _store = State(
      initialValue: HarnessMonitorPreviewStoreFactory.makeStore(
        for: .cockpitLoaded,
        environment: environment,
        hostBridgeOverride: PreviewHostBridgeOverride(
          bridgeStatus: BridgeStatusReport(running: false),
          reconfigureBehavior: .unsupported
        )
      )
    )
  }

  var body: some View {
    SessionCreateBridgeBanner(
      store: store,
      copy: SessionCreateBridgeBannerKind.agentTui.copy(
        store: store,
        environment: environment
      )
    )
    .frame(width: 720)
    .padding(24)
    .harnessPreviewSceneAppearance(textSizeIndex: textSizeIndex)
  }
}

@MainActor
public enum SessionCreateBridgeBannerPreviewRenderer {
  public static func dump(toDirectory directory: String) -> Bool {
    do {
      try FileManager.default.createDirectory(
        atPath: directory,
        withIntermediateDirectories: true
      )
    } catch {
      return false
    }

    return render(
      name: "session-create-bridge-banner-default",
      textSizeIndex: HarnessMonitorTextSize.defaultIndex,
      directory: directory
    )
      && render(
        name: "session-create-bridge-banner-largest-text",
        textSizeIndex: HarnessMonitorTextSize.scales.count - 1,
        directory: directory
      )
  }

  private static func render(
    name: String,
    textSizeIndex: Int,
    directory: String
  ) -> Bool {
    let content = SessionCreateBridgeBannerPreviewSurface(textSizeIndex: textSizeIndex)
    let view = NSHostingView(rootView: content)
    let size = view.fittingSize
    view.setFrameSize(size)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )
    window.contentView = view
    window.layoutIfNeeded()
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()

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
