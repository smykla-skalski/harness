import Foundation

enum PolicyCanvasMinimapCenteringMode: String, CaseIterable, Identifiable, Sendable {
  case centerButton
  case clickViewport

  static let defaultValue: Self = .centerButton

  var id: String { rawValue }

  var label: String {
    switch self {
    case .centerButton: "Center button"
    case .clickViewport: "Click viewport"
    }
  }

  var showsCenterButton: Bool {
    self == .centerButton
  }

  var recentersOnViewportClick: Bool {
    self == .clickViewport
  }
}

enum PolicyCanvasMinimapDefaults {
  static let isVisibleKey = "policyCanvas.minimap.isVisible"
  static let centeringModeKey = "policyCanvas.minimap.centeringMode"
  static let isVisibleDefault = true
}

private let minimapClickMovementThreshold: CGFloat = 6

func policyCanvasMinimapGestureIsClick(translation: CGSize) -> Bool {
  hypot(translation.width, translation.height) <= minimapClickMovementThreshold
}
