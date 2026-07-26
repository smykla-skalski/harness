import AppKit
import HarnessMonitorKit
import SwiftUI

/// Headless renderer for the lane color picker. Draws the picker off-screen
/// (no window, no focus change) so the popover layout can be reviewed from the
/// command line across appearance and text size. The PreviewHost executable
/// invokes this when `HARNESS_LANE_COLOR_PICKER_DUMP` is set, then exits before
/// any scene is shown.
@MainActor
public enum SettingsTaskBoardLaneColorPickerRenderer {
  /// Matches the width the appearance popover gives its content.
  private static let width: CGFloat = 360

  public static func dumpFixtures(toDirectory directory: String) {
    try? FileManager.default.createDirectory(
      atPath: directory,
      withIntermediateDirectories: true
    )
    for fixture in fixtures {
      write(render(fixture), named: fixture.name, directory: directory)
    }
  }

  private struct Fixture {
    let name: String
    let rawValue: String
    let themeMode: HarnessMonitorThemeMode
    let textSizeIndex: Int
  }

  private static var fixtures: [Fixture] {
    let preset = TaskBoardLaneAppearancePreferences.emptyRawValue
    let custom = TaskBoardLaneAppearancePreferences.settingCustomColor(
      Color(hue: 0.55, saturation: 0.72, brightness: 0.9),
      for: .inProgress,
      rawValue: preset
    )
    let defaultText = HarnessMonitorTextSize.defaultIndex
    let largestText = HarnessMonitorTextSize.scales.count - 1
    return [
      Fixture(name: "preset-dark", rawValue: preset, themeMode: .dark, textSizeIndex: defaultText),
      Fixture(
        name: "preset-light", rawValue: preset, themeMode: .light, textSizeIndex: defaultText),
      Fixture(name: "custom-dark", rawValue: custom, themeMode: .dark, textSizeIndex: defaultText),
      Fixture(
        name: "custom-light", rawValue: custom, themeMode: .light, textSizeIndex: defaultText),
      Fixture(
        name: "preset-dark-largest-text",
        rawValue: preset,
        themeMode: .dark,
        textSizeIndex: largestText
      ),
    ]
  }

  private static func render(_ fixture: Fixture) -> NSBitmapImageRep? {
    let root =
      SettingsTaskBoardLaneColorPicker(lane: .inProgress, rawValue: .constant(fixture.rawValue))
      .padding(HarnessMonitorTheme.spacingMD)
      .frame(width: width)
      // Stands in for the popover chrome. Without it the capture is
      // transparent and secondary text reads as invisible against whatever
      // the viewer happens to composite it onto.
      .background(Color(nsColor: .windowBackgroundColor))
      .harnessPreviewSceneAppearance(
        themeMode: fixture.themeMode,
        textSizeIndex: fixture.textSizeIndex
      )

    let hostingView = NSHostingView(rootView: root)
    // Theme colors are asset-backed, so they resolve against the view's own
    // appearance and not the scene modifier alone.
    hostingView.appearance = NSAppearance(
      named: fixture.themeMode == .light ? .aqua : .darkAqua
    )
    hostingView.frame = NSRect(
      x: 0,
      y: 0,
      width: width,
      height: hostingView.fittingSize.height
    )
    hostingView.layoutSubtreeIfNeeded()

    guard hostingView.bounds.width > 1, hostingView.bounds.height > 1,
      let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
    else {
      return nil
    }
    hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
    return rep
  }

  private static func write(_ rep: NSBitmapImageRep?, named name: String, directory: String) {
    guard let data = rep?.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
  }
}
