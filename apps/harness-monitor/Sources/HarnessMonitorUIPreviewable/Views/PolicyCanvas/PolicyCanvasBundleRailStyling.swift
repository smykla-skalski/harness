import AppKit
import CoreGraphics
import OSLog
import SwiftUI

private let policyCanvasBundleStylingLog = Logger(
  subsystem: "io.harnessmonitor",
  category: "policy-canvas.bundle-styling"
)

/// Maximum hue rotation applied across the rails of a single corridor bundle.
/// Capped to keep every rail within the original edge kind's perceptual
/// family - the kind's accent colour should still read first.
let policyCanvasBundleHueSpanDegrees: Double = 36

/// Hue offset in degrees for the given rail ordinal inside a corridor
/// bundle. Returns 0 when the bundle has a single rail (no offset needed).
/// Otherwise spreads ordinals symmetrically around the kind's base colour
/// within `policyCanvasBundleHueSpanDegrees`.
func policyCanvasBundleHueOffsetDegrees(
  bundleOrdinal: Int,
  bundleSize: Int
) -> Double {
  guard bundleSize > 1 else {
    return 0
  }
  let span = policyCanvasBundleHueSpanDegrees
  let mid = Double(bundleSize - 1) / 2
  let centeredOrdinal = Double(bundleOrdinal) - mid
  return centeredOrdinal * (span / Double(bundleSize - 1))
}

/// Rotates a Color's hue by `degrees` and returns a new Color in the same
/// colour space. Returns the original colour when the conversion to the
/// shared device colour space fails (some system dynamic colours have no
/// HSB representation).
func policyCanvasBundleHueRotated(_ color: Color, by degrees: Double) -> Color {
  guard degrees != 0 else {
    return color
  }
  let nsColor = NSColor(color)
  guard let rgb = nsColor.usingColorSpace(.deviceRGB) else {
    let colorSpaceName = String(describing: nsColor.colorSpace.localizedName)
    policyCanvasBundleStylingLog.debug(
      "hue rotation skipped: NSColor missing deviceRGB representation (\(colorSpaceName, privacy: .public))"
    )
    return color
  }
  var hue: CGFloat = 0
  var saturation: CGFloat = 0
  var brightness: CGFloat = 0
  var alpha: CGFloat = 0
  rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
  let normalisedDelta = CGFloat(degrees / 360)
  var newHue = hue + normalisedDelta
  newHue -= newHue.rounded(.down)
  let rotated = NSColor(
    deviceHue: newHue,
    saturation: saturation,
    brightness: brightness,
    alpha: alpha
  )
  return Color(nsColor: rotated)
}

/// Dash pattern variation for a bundle rail. Solid stays solid (ordinal 0
/// inside a size-1 bundle). For multi-rail bundles, cycle through a small
/// catalogue so neighbouring rails draw visually distinct strokes without
/// changing the underlying edge kind dash semantics.
func policyCanvasBundleRailDashPattern(
  kindDashPattern: [CGFloat],
  bundleOrdinal: Int,
  bundleSize: Int
) -> [CGFloat] {
  guard bundleSize > 1 else {
    return kindDashPattern
  }
  let catalogue: [[CGFloat]] = [
    kindDashPattern,
    [10, 4],
    [4, 4],
    [12, 4, 4, 4],
    [6, 4, 2, 4],
  ]
  return catalogue[bundleOrdinal % catalogue.count]
}
