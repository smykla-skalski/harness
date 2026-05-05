import Foundation

struct TimelineEntryMetadataPatch: Equatable, Sendable {
  let tapTarget: TimelineTapTarget?

  static let empty = TimelineEntryMetadataPatch(tapTarget: nil)
}
