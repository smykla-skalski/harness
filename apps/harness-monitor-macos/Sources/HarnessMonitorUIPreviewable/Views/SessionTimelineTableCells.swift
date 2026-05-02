import AppKit
import HarnessMonitorKit
import SwiftUI

final class SessionTimelineTableRowView: NSTableRowView {
  override func drawSelection(in _: NSRect) {}
}

final class SessionTimelineTableCellView: NSTableCellView {
  static let columnIdentifier = NSUserInterfaceItemIdentifier("session-timeline-column")
  static let cellIdentifier = NSUserInterfaceItemIdentifier("session-timeline-cell")

  private let hostingView = NSHostingView(rootView: SessionTimelineHostedRow.empty)

  init() {
    super.init(frame: .zero)
    identifier = Self.cellIdentifier
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
    hostingView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(hostingView)
    NSLayoutConstraint.activate([
      hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
      hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
      hostingView.topAnchor.constraint(equalTo: topAnchor),
      hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(row: SessionTimelineRow, actionHandler: any DecisionActionHandler) {
    hostingView.rootView = SessionTimelineHostedRow(row: row, actionHandler: actionHandler)
  }

  @MainActor private static let sizingHost = NSHostingView(
    rootView: SessionTimelineHostedRow.empty
  )

  @MainActor
  static func measuredHeight(for row: SessionTimelineRow, columnWidth: CGFloat) -> CGFloat {
    guard columnWidth > 1 else {
      return SessionTimelineTableMetrics.estimatedHeight(for: row)
    }
    return autoreleasepool {
      sizingHost.rootView = SessionTimelineHostedRow(
        row: row,
        actionHandler: NullDecisionActionHandler()
      )
      sizingHost.frame = NSRect(x: 0, y: 0, width: columnWidth, height: 2_000)
      sizingHost.layoutSubtreeIfNeeded()
      let measured = sizingHost.fittingSize.height
      return measured > 4 ? measured : SessionTimelineTableMetrics.estimatedHeight(for: row)
    }
  }

}

private struct SessionTimelineHostedRow: View {
  let row: SessionTimelineRow?
  let actionHandler: any DecisionActionHandler

  static var empty: Self {
    Self(row: nil, actionHandler: NullDecisionActionHandler())
  }

  var body: some View {
    if let row {
      ZStack(alignment: .topLeading) {
        Rectangle()
          .fill(HarnessMonitorTheme.controlBorder.opacity(0.55))
          .frame(width: 2)
          .offset(x: SessionTimelineLayout.railLineOffset - 1)
          .accessibilityHidden(true)

        SessionTimelineNodeCluster(row: row, actionHandler: actionHandler)
          .padding(.trailing, HarnessMonitorTheme.spacingXS)
          .padding(.bottom, HarnessMonitorTheme.itemSpacing)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
    } else {
      Color.clear.frame(height: SessionTimelineTableMetrics.estimatedBaseRowHeight)
    }
  }
}
