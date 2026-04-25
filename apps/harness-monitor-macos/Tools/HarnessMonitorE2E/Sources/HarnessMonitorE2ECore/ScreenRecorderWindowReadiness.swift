import CoreGraphics
import Foundation

/// Result of evaluating whether a candidate Harness Monitor window is
/// ready for ScreenCaptureKit capture.
///
/// `SCShareableContent.current` can report a window as `isOnScreen=true`
/// before AppKit has run its first layout pass, so the SCWindow's frame
/// is briefly `0x0` (or off any display). Passing such a window straight
/// to `SCContentFilter(desktopIndependentWindow:)` has been observed to
/// either fail silently or stall the recorder bootstrap on macOS 26, so
/// the recorder loops on this check and only proceeds once the window
/// has a real geometry that intersects an `SCDisplay`.
@available(macOS 15.0, *)
enum ScreenRecorderWindowReadinessResult {
  case ready(display: ScreenRecorderDisplayCandidate)
  case notReady(reason: String)
}

@available(macOS 15.0, *)
enum ScreenRecorderWindowReadiness {
  /// Decide whether a window with `windowFrame` is ready for capture given
  /// the current set of `SCDisplay` candidates. Returns `.ready` only when
  /// the frame has positive area and overlaps at least one display.
  static func evaluate(
    windowFrame: CGRect,
    displays: [ScreenRecorderDisplayCandidate]
  ) -> ScreenRecorderWindowReadinessResult {
    let normalized = windowFrame.standardized
    if normalized.isEmpty || normalized.width <= 0 || normalized.height <= 0 {
      return .notReady(reason: "zero-frame")
    }
    do {
      let display = try ScreenRecorderDisplaySelector.display(
        forWindowFrame: normalized,
        from: displays
      )
      return .ready(display: display)
    } catch {
      return .notReady(reason: "no-display-overlap")
    }
  }
}
