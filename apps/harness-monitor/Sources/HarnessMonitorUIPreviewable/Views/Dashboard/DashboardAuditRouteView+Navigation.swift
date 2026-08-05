struct DashboardAuditTimelineScrollTarget: Hashable {
  let eventID: String
  let requestID: Int

  static func resolve(
    _ target: Self?,
    availableEventIDs: Set<String>
  ) -> Self? {
    guard let target, availableEventIDs.contains(target.eventID) else { return nil }
    return target
  }
}

enum DashboardAuditSelectionVisibility {
  static func requiredLimit(
    selectedEventID: String,
    orderedEventIDs: [String],
    currentLimit: Int
  ) -> Int? {
    guard let selectedIndex = orderedEventIDs.firstIndex(of: selectedEventID) else {
      return nil
    }
    return max(currentLimit, selectedIndex + 1)
  }
}
