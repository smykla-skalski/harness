import CoreGraphics

/// Shared horizontal geometry for the diff grid. The code column's left inset
/// matches the renderer's draw offset, and the wrap budget reserves exactly one
/// character of right breathing room. Keeping the renderer (draw offset) and
/// the wrap engine (budget) on the same values stops the drawn column and the
/// wrap budget from drifting apart, which was the cause of the right-edge
/// clipping in tab-aligned hunks.
enum DashboardReviewFileDiffGridGeometry {
  /// Left inset of the unified code column; matches `drawUnified`'s `x: 120`.
  static let unifiedCodeLeftInset: CGFloat = 120

  /// Left inset of code text within a split column; matches `x + 76`.
  static let splitCodeLeftInset: CGFloat = 76

  /// Wrap budget for the unified code column: the drawable width minus the draw
  /// inset and one character of right margin, never below one character.
  static func unifiedCodeColumnWidth(
    contentWidth: CGFloat,
    characterWidth: CGFloat
  ) -> CGFloat {
    max(contentWidth - unifiedCodeLeftInset - characterWidth, characterWidth)
  }

  /// Wrap budget for one split code column, computed the same way against the
  /// per-side column width.
  static func splitCodeColumnWidth(
    columnWidth: CGFloat,
    characterWidth: CGFloat
  ) -> CGFloat {
    max(columnWidth - splitCodeLeftInset - characterWidth, characterWidth)
  }
}
