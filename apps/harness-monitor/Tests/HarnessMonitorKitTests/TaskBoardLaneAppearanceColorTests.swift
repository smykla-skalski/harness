import AppKit
import SwiftUI
import Testing

@testable import HarnessMonitorUIPreviewable

@MainActor
extension TaskBoardLaneAppearancePreferencesTests {
  @Test("Lane color components round-trip a stored color")
  func laneColorComponentsRoundTripAStoredColor() throws {
    let original = Color(.sRGB, red: 0.24, green: 0.58, blue: 0.87, opacity: 1)
    let restored = TaskBoardLaneColorComponents(original).color
    let originalRGB = try #require(NSColor(original).usingColorSpace(.sRGB))
    let restoredRGB = try #require(NSColor(restored).usingColorSpace(.sRGB))

    #expect(abs(originalRGB.redComponent - restoredRGB.redComponent) < 0.01)
    #expect(abs(originalRGB.greenComponent - restoredRGB.greenComponent) < 0.01)
    #expect(abs(originalRGB.blueComponent - restoredRGB.blueComponent) < 0.01)
  }

  @Test("A desaturated lane color no longer reports the hue that produced it")
  func desaturatedLaneColorLosesItsHue() {
    // This is why the picker holds the drag components in `@State` instead of
    // re-deriving them from the lane on every change: drag down to grey and
    // the stored color cannot say which hue you came from, so the marker would
    // jump to red mid-gesture.
    let grey = Color(hue: 0.6, saturation: 0, brightness: 0.5)

    #expect(TaskBoardLaneColorComponents(grey).hue == 0)
  }

  @Test("Lane palette hues resolve to calibrated theme assets, not raw system colours")
  func lanePaletteHuesResolveToThemeAssets() throws {
    let rawByToken: [(TaskBoardLaneColorToken, Color)] = [
      (.blue, .blue), (.teal, .teal), (.purple, .purple), (.pink, .pink), (.mint, .mint),
    ]
    let dark = try #require(NSAppearance(named: .darkAqua))
    var deltas: [TaskBoardLaneColorToken: Double] = [:]
    dark.performAsCurrentDrawingAppearance {
      for (token, raw) in rawByToken {
        guard
          let resolved = NSColor(token.color).usingColorSpace(.sRGB),
          let system = NSColor(raw).usingColorSpace(.sRGB)
        else { continue }
        deltas[token] =
          abs(Double(resolved.redComponent - system.redComponent))
          + abs(Double(resolved.greenComponent - system.greenComponent))
          + abs(Double(resolved.blueComponent - system.blueComponent))
      }
    }
    for (token, _) in rawByToken {
      let delta = try #require(deltas[token])
      #expect(delta > 0.05, "\(token) still resolves to the raw system colour")
    }
  }

  @Test("Umbrella lane default clears the WCAG AA luminance floor on the dark canvas")
  func umbrellaLaneDefaultClearsContrastFloor() throws {
    #expect(TaskBoardLaneAppearancePreferences.defaultColorToken(for: .umbrella) == .purple)
    let dark = try #require(NSAppearance(named: .darkAqua))
    var luminance = 0.0
    dark.performAsCurrentDrawingAppearance {
      guard let purple = NSColor(TaskBoardLaneColorToken.purple.color).usingColorSpace(.sRGB)
      else { return }
      luminance = Self.relativeLuminance(purple)
    }
    // Against the ~#1E1E1E board canvas (luminance ~0.013) a foreground needs a
    // relative luminance of ~0.234 to reach 4.5:1. Raw system purple measures
    // ~0.20 and fails; the calibrated purple must clear the floor.
    #expect(luminance >= 0.234)
  }

  private static func relativeLuminance(_ color: NSColor) -> Double {
    func linear(_ component: CGFloat) -> Double {
      let value = Double(component)
      return value <= 0.040_45 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(color.redComponent)
      + 0.7152 * linear(color.greenComponent)
      + 0.0722 * linear(color.blueComponent)
  }

}
