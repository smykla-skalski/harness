import SwiftUI

public func policyCanvasGroupTitleFrames(_ groups: [PolicyCanvasGroup]) -> [CGRect] {
  groups.map { group in
    policyCanvasGroupTitleFrame(in: group.frame)
  }
}

func policyCanvasGroupTitleFrame(in groupFrame: CGRect) -> CGRect {
  CGRect(
    x: groupFrame.minX + 8,
    y: groupFrame.minY + 8,
    width: min(groupFrame.width - 16, 180),
    height: 34
  )
}
