import CoreGraphics
import Foundation

@available(macOS 15.0, *)
struct ScreenRecorderDisplayCandidate: Equatable {
  let displayID: CGDirectDisplayID
  let frame: CGRect
}

@available(macOS 15.0, *)
enum ScreenRecorderDisplaySelector {
  static func display(
    forWindowFrame windowFrame: CGRect,
    from displays: [ScreenRecorderDisplayCandidate]
  ) throws -> ScreenRecorderDisplayCandidate {
    let normalizedWindowFrame = windowFrame.standardized
    guard
      let selected =
        displays
        .map({ candidate in
          (
            candidate: candidate,
            overlapArea: overlapArea(between: normalizedWindowFrame, and: candidate.frame)
          )
        })
        .filter({ $0.overlapArea > 0 })
        .max(by: { lhs, rhs in
          if lhs.overlapArea == rhs.overlapArea {
            return lhs.candidate.displayID > rhs.candidate.displayID
          }
          return lhs.overlapArea < rhs.overlapArea
        })?
        .candidate
    else {
      throw ScreenRecorder.Failure.monitorDisplayNotFound
    }
    return selected
  }

  private static func overlapArea(between lhs: CGRect, and rhs: CGRect) -> CGFloat {
    let intersection = lhs.intersection(rhs.standardized)
    guard !intersection.isNull, !intersection.isEmpty else {
      return 0
    }
    return intersection.width * intersection.height
  }
}
