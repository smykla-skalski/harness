import AppKit
import HarnessMonitorKit
import SwiftUI

/// Headless renderer for the lane appearance popover and its color picker.
/// Draws them off-screen (no window, no focus change) so the layout can be
/// reviewed from the command line across appearance and text size. The
/// PreviewHost executable invokes this when `HARNESS_LANE_COLOR_PICKER_DUMP` is
/// set, then exits before any scene is shown.
@MainActor
public enum SettingsTaskBoardLaneColorPickerRenderer {
  /// Matches the width the appearance popover gives its content.
  private static let width: CGFloat = 360

  /// Throws rather than skipping a fixture it cannot draw. A renderer that
  /// swallows its errors exits successfully having written nothing, and the
  /// missing image reads as a layout that produced no output.
  public static func dumpFixtures(toDirectory directory: String) throws {
    try FileManager.default.createDirectory(
      atPath: directory,
      withIntermediateDirectories: true
    )
    for fixture in fixtures {
      guard let rep = render(fixture) else {
        throw RenderFailure(fixture: fixture.name, reason: "view produced no drawable bitmap")
      }
      try write(rep, named: fixture.name, directory: directory)
    }
  }

  struct RenderFailure: Error, CustomStringConvertible {
    let fixture: String
    let reason: String

    var description: String { "\(fixture): \(reason)" }
  }

  private enum Surface {
    /// The color section on its own, for reviewing preset and custom states.
    case colorPicker
    /// The whole popover the Customize button opens, symbol grid included.
    case popover
  }

  private struct Fixture {
    let name: String
    let surface: Surface
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
      fixture("preset-dark", .colorPicker, preset, .dark, defaultText),
      fixture("preset-light", .colorPicker, preset, .light, defaultText),
      fixture("custom-dark", .colorPicker, custom, .dark, defaultText),
      fixture("custom-light", .colorPicker, custom, .light, defaultText),
      fixture("preset-dark-largest-text", .colorPicker, preset, .dark, largestText),
      fixture("popover-preset-dark", .popover, preset, .dark, defaultText),
      fixture("popover-preset-light", .popover, preset, .light, defaultText),
      fixture("popover-custom-dark", .popover, custom, .dark, defaultText),
      fixture("popover-preset-dark-largest-text", .popover, preset, .dark, largestText),
    ]
  }

  private static func fixture(
    _ name: String,
    _ surface: Surface,
    _ rawValue: String,
    _ themeMode: HarnessMonitorThemeMode,
    _ textSizeIndex: Int
  ) -> Fixture {
    Fixture(
      name: name,
      surface: surface,
      rawValue: rawValue,
      themeMode: themeMode,
      textSizeIndex: textSizeIndex
    )
  }

  @ViewBuilder
  private static func surfaceView(_ fixture: Fixture) -> some View {
    switch fixture.surface {
    case .colorPicker:
      SettingsTaskBoardLaneColorPicker(lane: .inProgress, rawValue: .constant(fixture.rawValue))
        .padding(HarnessMonitorTheme.spacingMD)
        .frame(width: width)
    case .popover:
      // Already carries the popover's own width and padding.
      SettingsTaskBoardLaneAppearancePopover(
        lane: .inProgress,
        rawValue: .constant(fixture.rawValue)
      )
    }
  }

  private static func render(_ fixture: Fixture) -> NSBitmapImageRep? {
    let root =
      surfaceView(fixture)
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
    let fittingSize = hostingView.fittingSize
    hostingView.frame = NSRect(
      x: 0,
      y: 0,
      width: max(width, fittingSize.width),
      height: fittingSize.height
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

  private static func write(
    _ rep: NSBitmapImageRep,
    named name: String,
    directory: String
  ) throws {
    guard let data = rep.representation(using: .png, properties: [:]), !data.isEmpty else {
      throw RenderFailure(fixture: name, reason: "bitmap did not encode to a non-empty PNG")
    }
    try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
  }
}
