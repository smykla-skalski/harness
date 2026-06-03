import SwiftUI

public func policyCanvasGroupTitleFrames(_ groups: [PolicyCanvasGroup]) -> [CGRect] {
  groups.map { group in
    CGRect(
      x: group.frame.minX + 8,
      y: group.frame.minY + 8,
      width: min(group.frame.width - 16, 180),
      height: 34
    )
  }
}
