import AppKit
import HarnessMonitorKit
import SwiftUI

struct SessionWindowRemovalSettingsPreview: View {
  let section: SettingsSection
  let store = SettingsPreviewSupport.makeStore()
  let notifications = HarnessMonitorUserNotificationController.preview()

  var body: some View {
    SettingsView(
      store: store,
      notifications: notifications,
      themeMode: .constant(.dark),
      selectedSection: .constant(section)
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct SessionWindowRemovalMenuBarPreview: View {
  let snapshot: HarnessMonitorMenuBarSnapshot

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Label(snapshot.statusItemDisplayTitle, systemImage: "light.beacon.max")
        .font(.headline)
        .padding(.bottom, HarnessMonitorTheme.spacingSM)

      menuRows(Array(snapshot.visibleMenuLabels.prefix(5)))
      Divider()
        .padding(.vertical, HarnessMonitorTheme.spacingXS)
      menuRows(Array(snapshot.visibleMenuLabels.dropFirst(5)))
    }
    .padding(HarnessMonitorTheme.spacingMD)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private func menuRows(_ labels: [String]) -> some View {
    ForEach(labels.enumerated(), id: \.offset) { _, label in
      Text(verbatim: label)
        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
    }
  }
}

public enum SessionWindowRemovalPreviewRenderer {
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

    return render(
      name: "settings-general",
      size: NSSize(width: 900, height: 640),
      view: SessionWindowRemovalSettingsPreview(section: .general),
      directory: directory
    )
      && render(
        name: "settings-appearance",
        size: NSSize(width: 900, height: 640),
        view: SessionWindowRemovalSettingsPreview(section: .appearance),
        directory: directory
      )
      && render(
        name: "menu-bar-active-work",
        size: NSSize(width: 360, height: 420),
        view: SessionWindowRemovalMenuBarPreview(
          snapshot: HarnessMonitorMenuBarSnapshot(
            connectionState: .online,
            pendingDecisionCount: 2,
            pendingDecisionSeverity: .warn,
            supervisorRuntimeState: .running,
            activeWorkCount: 4,
            runsWhenClosed: false
          )
        ),
        directory: directory
      )
      && render(
        name: "menu-bar-idle-attention",
        size: NSSize(width: 360, height: 420),
        view: SessionWindowRemovalMenuBarPreview(
          snapshot: HarnessMonitorMenuBarSnapshot(
            connectionState: .online,
            pendingDecisionCount: 1,
            pendingDecisionSeverity: .critical,
            supervisorRuntimeState: .running,
            activeWorkCount: 0,
            runsWhenClosed: true
          )
        ),
        directory: directory
      )
  }

  @MainActor
  private static func render<Content: View>(
    name: String,
    size: NSSize,
    view: Content,
    directory: String
  ) -> Bool {
    let hosted =
      view
      .frame(width: size.width, height: size.height, alignment: .topLeading)
      .background(Color(nsColor: .windowBackgroundColor))
      .harnessPreviewSceneAppearance()
    let hostingView = NSHostingView(rootView: hosted)
    hostingView.appearance = NSAppearance(named: .darkAqua)
    hostingView.setFrameSize(size)
    hostingView.layoutSubtreeIfNeeded()

    guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
      return false
    }
    hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
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
