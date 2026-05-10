import AppKit

final class SessionTimelineTableSpacerCellView: NSTableCellView {
  static let cellIdentifier = NSUserInterfaceItemIdentifier("session-timeline-spacer-cell")

  init() {
    super.init(frame: .zero)
    identifier = Self.cellIdentifier
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}
