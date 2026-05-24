import CoreGraphics

enum SessionTimelineCardLayout {
  static func prefersCompactLayout(for row: SessionTimelineRow) -> Bool {
    row.node.prefersCompactLayout ?? false
  }

  static func usesSimpleWideLayout(for row: SessionTimelineRow) -> Bool {
    !prefersCompactLayout(for: row)
      && row.node.detail == nil
      && row.node.actions.isEmpty
  }
}
