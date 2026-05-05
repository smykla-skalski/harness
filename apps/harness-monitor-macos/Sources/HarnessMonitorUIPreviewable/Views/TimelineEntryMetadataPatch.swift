import Foundation

struct TimelineEntryMetadataPatch: Equatable, Sendable {
  let tapTarget: TimelineTapTarget?

  static let empty = Self(tapTarget: nil)
}
