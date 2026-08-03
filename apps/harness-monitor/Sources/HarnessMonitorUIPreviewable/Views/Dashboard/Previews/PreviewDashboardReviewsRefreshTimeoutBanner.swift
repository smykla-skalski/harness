import AppKit
import SwiftUI

#Preview("Dashboard Reviews — refresh timeout") {
  DashboardReviewsRefreshTimeoutBanner(itemCount: 3, action: .constant(nil))
    .frame(width: 620)
    .padding()
    .harnessPreviewSceneAppearance()
}

public enum DashboardReviewsRefreshTimeoutPreviewRenderer {
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
      name: "refresh-timeout-single",
      itemCount: 1,
      size: NSSize(width: 620, height: 120),
      textSizeIndex: HarnessMonitorTextSize.defaultIndex,
      directory: directory
    )
      && render(
        name: "refresh-timeout-multiple-largest-text",
        itemCount: 12,
        size: NSSize(width: 760, height: 150),
        textSizeIndex: HarnessMonitorTextSize.scales.count - 1,
        directory: directory
      )
  }

  @MainActor
  private static func render(
    name: String,
    itemCount: Int,
    size: NSSize,
    textSizeIndex: Int,
    directory: String
  ) -> Bool {
    let hosted = DashboardReviewsRefreshTimeoutBanner(itemCount: itemCount, action: .constant(nil))
      .padding(.horizontal, HarnessMonitorTheme.spacingLG)
      .frame(width: size.width, height: size.height)
      .background(Color(nsColor: .windowBackgroundColor))
      .harnessPreviewSceneAppearance(textSizeIndex: textSizeIndex)
    let view = NSHostingView(rootView: hosted)
    view.appearance = NSAppearance(named: .darkAqua)
    view.setFrameSize(size)
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
