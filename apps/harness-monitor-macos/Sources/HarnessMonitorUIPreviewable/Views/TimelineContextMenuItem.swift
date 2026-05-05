import Foundation

enum TimelineContextMenuAction: Equatable, Sendable {
  case openSignal(id: String)
  case copyText(String)
}

struct TimelineContextMenuItem: Equatable, Sendable {
  let label: String
  let systemImage: String
  let action: TimelineContextMenuAction
}
