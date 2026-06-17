import Foundation

public enum PolicyCanvasLabToolbarDefaults {
  public static let sampleSelectionKey = "policyCanvasLabSampleSelection"
  public static let scalesZoomOnResizeKey = "policyCanvasLabScalesZoomOnResize"
  public static let defaultSampleSelectionRawValue = PolicyCanvasLabSamples.defaultSelectionID
  public static let scalesZoomOnResizeDefault = true

  public static func selection(
    in defaults: UserDefaults = .standard
  ) -> PolicyCanvasLabSelection? {
    selection(rawValue: defaults.string(forKey: sampleSelectionKey))
  }

  public static func scalesZoomOnResize(
    in defaults: UserDefaults = .standard
  ) -> Bool {
    guard defaults.object(forKey: scalesZoomOnResizeKey) != nil else {
      return scalesZoomOnResizeDefault
    }
    return defaults.bool(forKey: scalesZoomOnResizeKey)
  }

  public static func rawValue(for selection: PolicyCanvasLabSelection) -> String {
    switch selection {
    case .live:
      "live"
    case .sample(let id):
      id
    }
  }

  public static func selection(rawValue: String?) -> PolicyCanvasLabSelection? {
    guard let rawValue, !rawValue.isEmpty else {
      return nil
    }
    if rawValue == "live" {
      return .live
    }
    guard PolicyCanvasLabSamples.sample(id: rawValue) != nil else {
      return nil
    }
    return .sample(rawValue)
  }
}
