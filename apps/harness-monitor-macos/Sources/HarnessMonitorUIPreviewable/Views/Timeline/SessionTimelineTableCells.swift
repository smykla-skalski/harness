import AppKit
import HarnessMonitorKit
import SwiftUI

final class SessionTimelineTableRowView: NSTableRowView {
  override func drawSelection(in _: NSRect) {}
}

private final class SessionTimelineConnectorView: NSView {
  private static let strokeColor =
    NSColor(
      named: NSColor.Name("HarnessMonitorControlBorder"),
      bundle: HarnessMonitorUIAssets.bundle
    )?.withAlphaComponent(0.55) ?? NSColor.separatorColor.withAlphaComponent(0.55)

  var visibility: SessionTimelineConnectorVisibility = .all {
    didSet {
      if oldValue != visibility {
        needsDisplay = true
      }
    }
  }

  var markerCenterY: CGFloat = SessionTimelineTableMetrics.estimatedBaseRowHeight / 2 {
    didSet {
      if abs(oldValue - markerCenterY) > 0.5 {
        needsDisplay = true
      }
    }
  }

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = false
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_: NSPoint) -> NSView? {
    nil
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard visibility.showsConnectorAbove || visibility.showsConnectorBelow else {
      return
    }
    let x = SessionTimelineLayout.railLineOffset
    guard bounds.minX <= x, x <= bounds.maxX else {
      return
    }
    let centerY = min(max(markerCenterY, bounds.minY), bounds.maxY)
    let path = NSBezierPath()
    path.lineWidth = 2
    if visibility.showsConnectorAbove {
      path.move(to: NSPoint(x: x, y: bounds.minY))
      path.line(to: NSPoint(x: x, y: centerY))
    }
    if visibility.showsConnectorBelow {
      path.move(to: NSPoint(x: x, y: centerY))
      path.line(to: NSPoint(x: x, y: bounds.maxY))
    }
    Self.strokeColor.setStroke()
    path.stroke()
  }
}

private struct SessionTimelineTableCellConfiguration: Equatable {
  let row: SessionTimelineRow
  let fontScale: CGFloat
  let connectorVisibility: SessionTimelineConnectorVisibility
  let actionHandlerID: ObjectIdentifier
  let hasSignalTap: Bool
}

final class SessionTimelineTableCellView: NSTableCellView {
  static let columnIdentifier = NSUserInterfaceItemIdentifier("session-timeline-column")
  static let cellIdentifier = NSUserInterfaceItemIdentifier("session-timeline-cell")

  private let connectorView = SessionTimelineConnectorView()
  private let hostingView = NSHostingView(rootView: SessionTimelineHostedRow.empty)
  private var configuration: SessionTimelineTableCellConfiguration?

  init() {
    super.init(frame: .zero)
    identifier = Self.cellIdentifier
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
    addSubview(connectorView)
    hostingView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(hostingView)
    NSLayoutConstraint.activate([
      connectorView.leadingAnchor.constraint(equalTo: leadingAnchor),
      connectorView.trailingAnchor.constraint(equalTo: trailingAnchor),
      connectorView.topAnchor.constraint(equalTo: topAnchor),
      connectorView.bottomAnchor.constraint(equalTo: bottomAnchor),
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
    onSignalTap: ((String) -> Void)?,
    fontScale: CGFloat,
    connectorVisibility: SessionTimelineConnectorVisibility
  ) {
    let nextConfiguration = SessionTimelineTableCellConfiguration(
      row: row,
      fontScale: fontScale,
      connectorVisibility: connectorVisibility,
      actionHandlerID: ObjectIdentifier(actionHandler),
      hasSignalTap: onSignalTap != nil
    )
    guard configuration != nextConfiguration else {
      return
    }
    configuration = nextConfiguration
    connectorView.visibility = connectorVisibility
    connectorView.markerCenterY = SessionTimelineTableMetrics.estimatedMarkerCenterY(
      for: row,
      fontScale: fontScale
    )
    hostingView.rootView = SessionTimelineHostedRow(
      row: row,
      actionHandler: actionHandler,
      onSignalTap: onSignalTap,
      fontScale: fontScale
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
      return SessionTimelineTableMetrics.estimatedHeight(for: row, fontScale: fontScale)
    }
    return autoreleasepool {
      sizingHost.rootView = SessionTimelineHostedRow(
        row: row,
        actionHandler: NullDecisionActionHandler(),
        fontScale: fontScale
      )
      sizingHost.frame = NSRect(x: 0, y: 0, width: columnWidth, height: 2_000)
      sizingHost.invalidateIntrinsicContentSize()
      sizingHost.needsLayout = true
      sizingHost.layoutSubtreeIfNeeded()
      let measured = ceil(sizingHost.fittingSize.height)
      guard measured > 4 else {
        return SessionTimelineTableMetrics.estimatedHeight(for: row, fontScale: fontScale)
      }
      return measured
    }
  }

}

private struct SessionTimelineHostedRow: View {
  let row: SessionTimelineRow?
  let actionHandler: any DecisionActionHandler
  let onSignalTap: ((String) -> Void)?
  let fontScale: CGFloat

  init(
    row: SessionTimelineRow?,
    actionHandler: any DecisionActionHandler,
    onSignalTap: ((String) -> Void)? = nil,
    fontScale: CGFloat
  ) {
    self.row = row
    self.actionHandler = actionHandler
    self.onSignalTap = onSignalTap
    self.fontScale = fontScale
  }

  static var empty: Self {
    Self(row: nil, actionHandler: NullDecisionActionHandler(), fontScale: 1.0)
  }

  var body: some View {
    Group {
      if let row {
        populatedRow(row)
      } else {
        Color.clear.frame(height: SessionTimelineTableMetrics.estimatedBaseRowHeight)
      }
    }
    .environment(\.fontScale, fontScale)
    .transaction { transaction in
      transaction.animation = nil
      transaction.disablesAnimations = true
    }
  }

  private func populatedRow(_ row: SessionTimelineRow) -> some View {
    SessionTimelineNodeCluster(row: row, actionHandler: actionHandler, onSignalTap: onSignalTap)
      .equatable()
      .padding(.trailing, HarnessMonitorTheme.spacingXS)
      .padding(.bottom, SessionTimelineTableMetrics.rowBottomPadding(for: row))
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
  }
}
