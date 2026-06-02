import Foundation

public enum PolicyCanvasMinimapCenteringMode: String, CaseIterable, Identifiable, Sendable {
  case centerButton
  case clickViewport

  public static let defaultValue: Self = .centerButton

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .centerButton: "Center button"
    case .clickViewport: "Click viewport"
    }
  }

  public var showsCenterButton: Bool {
    self == .centerButton
  }

  public var recentersOnViewportClick: Bool {
    self == .clickViewport
  }
}

public enum PolicyCanvasMinimapDefaults {
  public static let isVisibleKey = "policyCanvas.minimap.isVisible"
  public static let centeringModeKey = "policyCanvas.minimap.centeringMode"
  public static let isVisibleDefault = true
}

private let minimapClickMovementThreshold: CGFloat = 6

func policyCanvasMinimapGestureIsClick(translation: CGSize) -> Bool {
  hypot(translation.width, translation.height) <= minimapClickMovementThreshold
}
