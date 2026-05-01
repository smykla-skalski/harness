import CoreGraphics

struct SessionTimelineTableSnapshot: Equatable {
  let rows: [SessionTimelineTableRowSnapshot]

  static let empty = Self(rowSnapshots: [])

  init(rows: [SessionTimelineRow]) {
    self.rows = rows.map(SessionTimelineTableRowSnapshot.init)
  }

  private init(rowSnapshots: [SessionTimelineTableRowSnapshot]) {
    rows = rowSnapshots
  }
}

struct SessionTimelineTableRowSnapshot: Equatable {
  let id: String
  let height: CGFloat
  let dayDividerLabel: String?
  let timestampLabel: String
  let accessibilityLabel: String
  let kindLabel: String
  let sourceLabel: String
  let title: String
  let detail: String?
  let toneLabel: String?
  let decisionID: String?
  let decisionSeverityLabel: String?
  let actionIDs: [String]
  let actionKinds: [String]
  let actionTitles: [String]
  let actionPayloads: [String]
  let primaryActionIDs: [String]

  init(row: SessionTimelineRow) {
    id = row.id
    height = SessionTimelineTableMetrics.estimatedHeight(for: row)
    dayDividerLabel = row.dayDividerLabel
    timestampLabel = row.timestampLabel
    accessibilityLabel = row.accessibilityLabel
    kindLabel = row.node.kind.label
    sourceLabel = row.node.sourceLabel
    title = row.node.title
    detail = row.node.detail
    toneLabel = row.node.eventTone?.label
    decisionID = row.node.decision?.id
    decisionSeverityLabel = row.node.decision?.severityLabel
    actionIDs = row.node.actions.map(\.id)
    actionKinds = row.node.actions.map { String(describing: $0.kind) }
    actionTitles = row.node.actions.map(\.title)
    actionPayloads = row.node.actions.map(\.payloadJSON)
    primaryActionIDs = row.node.actions.filter(\.isPrimary).map(\.id)
  }
}
