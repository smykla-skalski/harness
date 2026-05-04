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

  func update(
    row: SessionTimelineRow,
    actionHandler: any DecisionActionHandler,
    fontScale: CGFloat,
    showsConnectorAbove: Bool,
    showsConnectorBelow: Bool
  ) {
    hostingView.rootView = SessionTimelineHostedRow(
      row: row,
      actionHandler: actionHandler,
      fontScale: fontScale,
      showsConnectorAbove: showsConnectorAbove,
      showsConnectorBelow: showsConnectorBelow
    )
  }

  @MainActor private static let sizingHost = NSHostingView(
    rootView: SessionTimelineHostedRow.empty
  )

  @MainActor
  static func measuredHeight(
    for row: SessionTimelineRow,
    columnWidth: CGFloat,
    fontScale: CGFloat = 1.0
  ) -> CGFloat {
    guard columnWidth > 1 else {
      return SessionTimelineTableMetrics.estimatedHeight(for: row)
    }
    return autoreleasepool {
      sizingHost.rootView = SessionTimelineHostedRow(
        row: row,
        actionHandler: NullDecisionActionHandler(),
        fontScale: fontScale
      )
      sizingHost.frame = NSRect(x: 0, y: 0, width: columnWidth, height: 2_000)
      sizingHost.layoutSubtreeIfNeeded()
      let measured = ceil(sizingHost.fittingSize.height)
      return measured > 4 ? measured : SessionTimelineTableMetrics.estimatedHeight(for: row)
    }
  }

}

private struct SessionTimelineHostedRow: View {
  let row: SessionTimelineRow?
  let actionHandler: any DecisionActionHandler
  let fontScale: CGFloat
  let showsConnectorAbove: Bool
  let showsConnectorBelow: Bool

  init(
    row: SessionTimelineRow?,
    actionHandler: any DecisionActionHandler,
    fontScale: CGFloat,
    showsConnectorAbove: Bool = true,
    showsConnectorBelow: Bool = true
  ) {
    self.row = row
    self.actionHandler = actionHandler
    self.fontScale = fontScale
    self.showsConnectorAbove = showsConnectorAbove
    self.showsConnectorBelow = showsConnectorBelow
  }

  static var empty: Self {
    Self(row: nil, actionHandler: NullDecisionActionHandler(), fontScale: 1.0)
  }

  var body: some View {
    Group {
      if let row {
        SessionTimelineNodeCluster(row: row, actionHandler: actionHandler)
          .padding(.trailing, HarnessMonitorTheme.spacingXS)
          .padding(.bottom, SessionTimelineTableMetrics.rowBottomPadding(for: row))
          .overlayPreferenceValue(SessionTimelineMarkerBoundsKey.self) { markerAnchor in
            SessionTimelineConnectorOverlay(
              markerAnchor: markerAnchor,
              showsConnectorAbove: showsConnectorAbove,
              showsConnectorBelow: showsConnectorBelow
            )
          }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
      } else {
        Color.clear.frame(height: SessionTimelineTableMetrics.estimatedBaseRowHeight)
      }
    }
    .environment(\.fontScale, fontScale)
  }
}
