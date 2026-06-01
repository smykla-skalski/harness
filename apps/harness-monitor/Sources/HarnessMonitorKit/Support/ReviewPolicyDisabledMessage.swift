import Foundation

public func harnessMonitorReviewPolicyDisabledMessage(from message: String) -> String? {
  let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
  let lowercased = trimmed.lowercased()
  let prefix = "reviews github "
  let marker = " is disabled because "
  guard let prefixRange = lowercased.range(of: prefix),
    let markerRange = lowercased.range(
      of: marker,
      range: prefixRange.upperBound..<lowercased.endIndex
    )
  else {
    return nil
  }
  let reasonOffset = lowercased.distance(
    from: lowercased.startIndex,
    to: markerRange.upperBound
  )
  let reasonStart = trimmed.index(trimmed.startIndex, offsetBy: reasonOffset)
  let reason = String(trimmed[reasonStart...])
    .trimmingCharacters(in: .whitespacesAndNewlines)
    .harnessMonitorTrimmedTrailingPeriod
  guard !reason.isEmpty else { return nil }
  return """
    This GitHub review action is disabled by policy: \(reason). Activate an \
    enforced Policy Canvas that allows it, then retry
    """
}
